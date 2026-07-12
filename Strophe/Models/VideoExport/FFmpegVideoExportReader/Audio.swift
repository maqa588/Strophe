//
//  FFmpegVideoExportReader+Audio.swift
//  Strophe
//
//  Created by Antigravity on 2026/07/12.
//

import AVFoundation
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample

nonisolated final class FFmpegVideoExportAudioReader {
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swrContext: OpaquePointer?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var pendingSampleBuffer: CMSampleBuffer?
    private var nextFallbackPTS: Double = 0
    private var reachedEOF = false

    private(set) var audioStreamIndex: Int32 = -1
    private(set) var sampleRate: Int32 = 48_000
    private(set) var channelCount: Int32 = 2
    var timeOffset: Double = 0
    var isFinished = false

    var writerOutputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: Int(channelCount),
            AVSampleRateKey: Double(sampleRate),
            AVEncoderBitRateKey: min(max(Int(channelCount) * 96_000, 128_000), 320_000)
        ]
    }

    init(url: URL) throws {
        try open(url: url)
    }

    deinit {
        close()
    }

    func close() {
        pendingSampleBuffer = nil
        if let frame {
            var value: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&value)
            self.frame = nil
        }
        if let packet {
            var value: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&value)
            self.packet = nil
        }
        if let swrContext {
            var value: OpaquePointer? = swrContext
            swr_free(&value)
            self.swrContext = nil
        }
        if let codecContext {
            var value: UnsafeMutablePointer<AVCodecContext>? = codecContext
            avcodec_free_context(&value)
            self.codecContext = nil
        }
        if let formatContext {
            var value: UnsafeMutablePointer<AVFormatContext>? = formatContext
            avformat_close_input(&value)
            self.formatContext = nil
        }
    }

    func peekSampleBuffer() throws -> CMSampleBuffer? {
        if let pendingSampleBuffer {
            return pendingSampleBuffer
        }
        pendingSampleBuffer = try nextSampleBuffer()
        return pendingSampleBuffer
    }

    func consumePeekedSampleBuffer() throws -> CMSampleBuffer? {
        if let pendingSampleBuffer {
            self.pendingSampleBuffer = nil
            return pendingSampleBuffer
        }
        return try nextSampleBuffer()
    }

    private func open(url: URL) throws {
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&ctx, url.path, nil, nil) >= 0, let openedContext = ctx else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("无法打开音频输入文件。")
        }
        formatContext = openedContext

        guard avformat_find_stream_info(openedContext, nil) >= 0 else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("无法读取音频流信息。")
        }

        for index in 0..<openedContext.pointee.nb_streams {
            guard let stream = openedContext.pointee.streams[Int(index)] else { continue }
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                audioStreamIndex = Int32(index)
                break
            }
        }

        guard audioStreamIndex >= 0,
              let stream = openedContext.pointee.streams[Int(audioStreamIndex)] else {
            throw HardSubtitleVideoExportError.missingVideoTrack
        }

        let codecParameters = stream.pointee.codecpar!
        guard let decoder = avcodec_find_decoder(codecParameters.pointee.codec_id) else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("找不到可用的音频解码器。")
        }

        let decoderContext = avcodec_alloc_context3(decoder)
        guard let decoderContext else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("无法创建音频解码上下文。")
        }
        codecContext = decoderContext
        avcodec_parameters_to_context(decoderContext, codecParameters)

        guard avcodec_open2(decoderContext, decoder, nil) >= 0 else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("无法打开音频解码器。")
        }

        sampleRate = decoderContext.pointee.sample_rate > 0 ? decoderContext.pointee.sample_rate : 48_000
        channelCount = max(1, min(decoderContext.pointee.ch_layout.nb_channels, 2))
        try setupResampler()

        packet = av_packet_alloc()
        frame = av_frame_alloc()
        guard packet != nil, frame != nil else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("无法分配音频解码缓冲。")
        }
    }

    private func setupResampler() throws {
        guard let codecContext else { return }
        let resampler = swr_alloc()
        guard let resampler else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("无法创建音频重采样器。")
        }
        swrContext = resampler

        let rawResampler = UnsafeMutableRawPointer(resampler)
        var outputLayout = AVChannelLayout()
        av_channel_layout_default(&outputLayout, channelCount)

        av_opt_set_chlayout(rawResampler, "in_chlayout", &codecContext.pointee.ch_layout, 0)
        av_opt_set_int(rawResampler, "in_sample_rate", Int64(codecContext.pointee.sample_rate), 0)
        av_opt_set_sample_fmt(rawResampler, "in_sample_fmt", codecContext.pointee.sample_fmt, 0)
        av_opt_set_chlayout(rawResampler, "out_chlayout", &outputLayout, 0)
        av_opt_set_int(rawResampler, "out_sample_rate", Int64(sampleRate), 0)
        av_opt_set_sample_fmt(rawResampler, "out_sample_fmt", AV_SAMPLE_FMT_FLT, 0)

        guard swr_init(resampler) >= 0 else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("无法初始化音频重采样器。")
        }
    }

    private func nextSampleBuffer() throws -> CMSampleBuffer? {
        guard !isFinished,
              let formatContext,
              let codecContext,
              let swrContext,
              let packet,
              let frame else {
            return nil
        }

        while true {
            let receiveStatus = avcodec_receive_frame(codecContext, frame)
            if receiveStatus >= 0 {
                defer { av_frame_unref(frame) }
                return try sampleBuffer(from: frame, formatContext: formatContext, resampler: swrContext)
            }

            if reachedEOF {
                isFinished = true
                return nil
            }

            av_packet_unref(packet)
            let readStatus = av_read_frame(formatContext, packet)
            if readStatus < 0 {
                reachedEOF = true
                avcodec_send_packet(codecContext, nil)
                continue
            }

            guard packet.pointee.stream_index == audioStreamIndex else {
                continue
            }

            let sendStatus = avcodec_send_packet(codecContext, packet)
            if sendStatus < 0 && sendStatus != -EAGAIN {
                throw HardSubtitleVideoExportError.ffmpegDecodeFailed("avcodec_send_packet(audio) failed: \(sendStatus)")
            }
        }
    }

    private func sampleBuffer(
        from frame: UnsafeMutablePointer<AVFrame>,
        formatContext: UnsafeMutablePointer<AVFormatContext>,
        resampler: OpaquePointer
    ) throws -> CMSampleBuffer? {
        let inputSamples = Int(frame.pointee.nb_samples)
        guard inputSamples > 0 else { return nil }

        let delayedSamples = swr_get_delay(resampler, Int64(sampleRate))
        let outputCapacity = Int(av_rescale_rnd(
            delayedSamples + Int64(inputSamples),
            Int64(sampleRate),
            Int64(max(frame.pointee.sample_rate, 1)),
            AV_ROUND_UP
        ))
        let sampleByteCount = MemoryLayout<Float>.size * Int(channelCount)
        let byteCapacity = outputCapacity * sampleByteCount
        let audioData = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCapacity)

        var outputData: [UnsafeMutablePointer<UInt8>?] = [audioData, nil, nil, nil, nil, nil, nil, nil]
        let sourceData = withUnsafePointer(to: &frame.pointee.data) {
            $0.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { $0 }
        }

        let convertedSamples = swr_convert(
            resampler,
            &outputData,
            Int32(outputCapacity),
            sourceData,
            Int32(inputSamples)
        )

        guard convertedSamples > 0 else {
            audioData.deallocate()
            return nil
        }

        let dataLength = Int(convertedSamples) * sampleByteCount
        let presentationTime = audioPTS(frame, formatContext: formatContext)
        let sampleBuffer = try makeAudioSampleBuffer(
            audioData: audioData,
            dataLength: dataLength,
            sampleCount: Int(convertedSamples),
            presentationTime: presentationTime
        )
        nextFallbackPTS = presentationTime + Double(convertedSamples) / Double(sampleRate)
        return sampleBuffer
    }

    private func audioPTS(
        _ frame: UnsafeMutablePointer<AVFrame>,
        formatContext: UnsafeMutablePointer<AVFormatContext>
    ) -> Double {
        let timestamp = frame.pointee.best_effort_timestamp != ffmpegExportNoPTS
            ? frame.pointee.best_effort_timestamp
            : frame.pointee.pts
        guard timestamp != ffmpegExportNoPTS,
              let stream = formatContext.pointee.streams[Int(audioStreamIndex)] else {
            return max(0, nextFallbackPTS - timeOffset)
        }
        let timeBase = stream.pointee.time_base
        return max(0, Double(timestamp) * Double(timeBase.num) / Double(timeBase.den) - timeOffset)
    }

    private func makeAudioSampleBuffer(
        audioData: UnsafeMutablePointer<UInt8>,
        dataLength: Int,
        sampleCount: Int,
        presentationTime: Double
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            audioData.deallocate()
            throw HardSubtitleVideoExportError.audioMuxFailed("无法创建音频块缓冲。")
        }
        let copyStatus = CMBlockBufferReplaceDataBytes(
            with: audioData,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: dataLength
        )
        audioData.deallocate()
        guard copyStatus == kCMBlockBufferNoErr else {
            throw HardSubtitleVideoExportError.audioMuxFailed("无法写入音频块缓冲。")
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * Int(channelCount)),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * Int(channelCount)),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw HardSubtitleVideoExportError.audioMuxFailed("无法创建音频格式描述。")
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(seconds: presentationTime, preferredTimescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleSize = dataLength / sampleCount
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw HardSubtitleVideoExportError.audioMuxFailed("无法创建音频采样缓冲。")
        }

        return sampleBuffer
    }
}
