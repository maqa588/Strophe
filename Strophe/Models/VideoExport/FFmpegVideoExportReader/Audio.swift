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
    private var nextFallbackSourcePTS: Double = 0
    private var reachedEOF = false
    private var packetNeedsSending = false
    private var sentDrainPacket = false

    private(set) var audioStreamIndex: Int32 = -1
    private(set) var sampleRate: Int32 = 48_000
    private(set) var channelCount: Int32 = 2
    var timeOffset: Double = 0
    var minimumSourceTime: Double = 0
    var maximumSourceTime: Double?
    var isFinished = false

    var writerOutputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: Int(channelCount),
            AVSampleRateKey: Double(sampleRate),
            AVEncoderBitRateKey: min(max(Int(channelCount) * 96_000, 128_000), 320_000),
        ]
    }

    init(url: URL, audioTrackOrdinal: Int = 0) throws {
        try open(url: url, audioTrackOrdinal: audioTrackOrdinal)
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

    /// Starts ranged audio decoding at the preceding packet instead of walking
    /// every packet from the beginning. `minimumSourceTime` still performs the
    /// exact sample-level trim after this coarse seek.
    @discardableResult
    func seek(to seconds: Double) -> Bool {
        guard seconds.isFinite,
            seconds > 0,
            let formatContext,
            let codecContext,
            let stream = formatContext.pointee.streams[Int(audioStreamIndex)],
            stream.pointee.time_base.num > 0,
            stream.pointee.time_base.den > 0
        else {
            return false
        }
        let timeBase = stream.pointee.time_base
        let targetPTS = Int64(
            seconds * Double(timeBase.den) / Double(timeBase.num)
        )
        guard
            av_seek_frame(
                formatContext,
                audioStreamIndex,
                targetPTS,
                AVSEEK_FLAG_BACKWARD
            ) >= 0
        else {
            return false
        }

        avcodec_flush_buffers(codecContext)
        if let packet { av_packet_unref(packet) }
        if let frame { av_frame_unref(frame) }
        if let swrContext {
            swr_close(swrContext)
            guard swr_init(swrContext) >= 0 else { return false }
        }
        pendingSampleBuffer = nil
        nextFallbackSourcePTS = seconds
        reachedEOF = false
        packetNeedsSending = false
        sentDrainPacket = false
        isFinished = false
        return true
    }

    private func open(url: URL, audioTrackOrdinal: Int) throws {
        guard audioTrackOrdinal >= 0 else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("Invalid audio track selection.")
        }
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&ctx, url.path, nil, nil) >= 0, let openedContext = ctx else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("无法打开音频输入文件。")
        }
        formatContext = openedContext

        guard avformat_find_stream_info(openedContext, nil) >= 0 else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("无法读取音频流信息。")
        }

        var encounteredAudioTracks = 0
        for index in 0..<openedContext.pointee.nb_streams {
            guard let stream = openedContext.pointee.streams[Int(index)],
                let codecParameters = stream.pointee.codecpar
            else { continue }
            if codecParameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                if encounteredAudioTracks == audioTrackOrdinal {
                    audioStreamIndex = Int32(index)
                    break
                }
                encounteredAudioTracks += 1
            }
        }

        guard audioStreamIndex >= 0,
            let stream = openedContext.pointee.streams[Int(audioStreamIndex)],
            let codecParameters = stream.pointee.codecpar
        else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed(
                "Audio track \(audioTrackOrdinal + 1) is unavailable."
            )
        }

        guard let decoder = avcodec_find_decoder(codecParameters.pointee.codec_id) else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("找不到可用的音频解码器。")
        }

        let decoderContext = avcodec_alloc_context3(decoder)
        guard let decoderContext else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("无法创建音频解码上下文。")
        }
        codecContext = decoderContext
        guard avcodec_parameters_to_context(decoderContext, codecParameters) >= 0 else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed(
                "Unable to configure the audio decoder."
            )
        }

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
            let frame
        else {
            return nil
        }

        while true {
            // FFmpeg requires an empty destination frame for every receive call.
            // Keeping this explicit also makes all early-return paths safe.
            av_frame_unref(frame)
            let receiveStatus = avcodec_receive_frame(codecContext, frame)
            if receiveStatus >= 0 {
                defer { av_frame_unref(frame) }
                let sourcePresentationTime = sourceAudioPTS(
                    frame,
                    formatContext: formatContext
                )
                let sourceDuration =
                    Double(max(frame.pointee.nb_samples, 0))
                    / Double(max(sampleRate, 1))
                nextFallbackSourcePTS = sourcePresentationTime + sourceDuration
                if sourcePresentationTime + sourceDuration <= minimumSourceTime {
                    continue
                }
                if let maximumSourceTime,
                    sourcePresentationTime >= maximumSourceTime
                {
                    isFinished = true
                    return nil
                }
                return try sampleBuffer(
                    from: frame,
                    resampler: swrContext,
                    sourcePresentationTime: sourcePresentationTime
                )
            }

            if receiveStatus != -EAGAIN {
                if reachedEOF {
                    isFinished = true
                    return nil
                }
                throw HardSubtitleVideoExportError.ffmpegDecodeFailed(
                    "avcodec_receive_frame(audio) failed: \(receiveStatus)"
                )
            }

            // A packet rejected with EAGAIN is still owned by the caller and
            // must be retried after draining decoder output; never overwrite it
            // with the next demuxed packet.
            if packetNeedsSending {
                let sendStatus = avcodec_send_packet(codecContext, packet)
                if sendStatus >= 0 {
                    packetNeedsSending = false
                    av_packet_unref(packet)
                } else if sendStatus != -EAGAIN {
                    packetNeedsSending = false
                    av_packet_unref(packet)
                    throw HardSubtitleVideoExportError.ffmpegDecodeFailed(
                        "avcodec_send_packet(audio) failed: \(sendStatus)"
                    )
                }
                continue
            }

            if reachedEOF {
                if !sentDrainPacket {
                    let drainStatus = avcodec_send_packet(codecContext, nil)
                    if drainStatus >= 0 {
                        sentDrainPacket = true
                        continue
                    }
                    if drainStatus == -EAGAIN {
                        continue
                    }
                }
                isFinished = true
                return nil
            }

            av_packet_unref(packet)
            while true {
                let readStatus = av_read_frame(formatContext, packet)
                if readStatus < 0 {
                    reachedEOF = true
                    break
                }
                guard packet.pointee.stream_index == audioStreamIndex else {
                    av_packet_unref(packet)
                    continue
                }
                packetNeedsSending = true
                break
            }
        }
    }

    private func sampleBuffer(
        from frame: UnsafeMutablePointer<AVFrame>,
        resampler: OpaquePointer,
        sourcePresentationTime: Double
    ) throws -> CMSampleBuffer? {
        let inputSamples = Int(frame.pointee.nb_samples)
        guard inputSamples > 0 else { return nil }

        let delayedSamples = swr_get_delay(resampler, Int64(sampleRate))
        let outputCapacity = Int(
            av_rescale_rnd(
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
        let presentationTime = max(0, sourcePresentationTime - timeOffset)
        let sampleBuffer = try makeAudioSampleBuffer(
            audioData: audioData,
            dataLength: dataLength,
            sampleCount: Int(convertedSamples),
            presentationTime: presentationTime
        )
        return sampleBuffer
    }

    private func sourceAudioPTS(
        _ frame: UnsafeMutablePointer<AVFrame>,
        formatContext: UnsafeMutablePointer<AVFormatContext>
    ) -> Double {
        let timestamp =
            frame.pointee.best_effort_timestamp != ffmpegExportNoPTS
            ? frame.pointee.best_effort_timestamp
            : frame.pointee.pts
        guard timestamp != ffmpegExportNoPTS,
            let stream = formatContext.pointee.streams[Int(audioStreamIndex)]
        else {
            return max(0, nextFallbackSourcePTS)
        }
        let timeBase = stream.pointee.time_base
        return max(0, Double(timestamp) * Double(timeBase.num) / Double(timeBase.den))
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
