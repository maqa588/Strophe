//
//  AudioExtractor.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/28.
//

import Foundation
import AVFoundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample

nonisolated enum AudioExtractor {

    /// Decodes the best audio stream with FFmpeg and resamples it to mono Float32 PCM.
    /// - Parameters:
    ///   - url: Local media URL.
    ///   - targetSampleRate: Output sample rate, such as 16 kHz for ASR.
    /// - Returns: Mono PCM samples normalized to `Float`.
    static func extract(from url: URL, targetSampleRate: Double = 16_000) async throws -> [Float] {
        guard targetSampleRate.isFinite, (1...768_000).contains(targetSampleRate) else {
            throw NSError(
                domain: "AudioExtractor",
                code: 15,
                userInfo: [NSLocalizedDescriptionKey: "Invalid target audio sample rate."]
            )
        }
        return try await Task.detached(priority: .userInitiated) {
            let path = url.path

            var formatContext: UnsafeMutablePointer<AVFormatContext>?
            guard avformat_open_input(&formatContext, path, nil, nil) >= 0,
                let openedFormatContext = formatContext
            else {
                throw NSError(
                    domain: "AudioExtractor",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "FFmpeg 无法打开输入文件: \(url.lastPathComponent)"]
                )
            }
            defer {
                avformat_close_input(&formatContext)
            }

            if avformat_find_stream_info(openedFormatContext, nil) < 0 {
                throw NSError(
                    domain: "AudioExtractor",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "无法获取媒体流信息。"]
                )
            }

            let audioStreamIndex = av_find_best_stream(
                openedFormatContext,
                AVMEDIA_TYPE_AUDIO,
                -1,
                -1,
                nil,
                0
            )
            guard audioStreamIndex >= 0 else {
                throw NSError(
                    domain: "AudioExtractor",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "媒体文件中未找到可用的音频轨道。"]
                )
            }

            guard let stream = openedFormatContext.pointee.streams[Int(audioStreamIndex)],
                let codecpar = stream.pointee.codecpar
            else {
                throw NSError(
                    domain: "AudioExtractor",
                    code: 22,
                    userInfo: [NSLocalizedDescriptionKey: "The selected audio stream is invalid."]
                )
            }

            guard let decoder = avcodec_find_decoder(codecpar.pointee.codec_id) else {
                throw NSError(
                    domain: "AudioExtractor",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "找不到对应音频轨道的解码器。"]
                )
            }

            let codecContext = avcodec_alloc_context3(decoder)
            guard let codecContext = codecContext else {
                throw NSError(
                    domain: "AudioExtractor",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "无法分配解码器上下文。"]
                )
            }
            defer {
                var temp: UnsafeMutablePointer<AVCodecContext>? = codecContext
                avcodec_free_context(&temp)
            }

            guard avcodec_parameters_to_context(codecContext, codecpar) >= 0 else {
                throw NSError(
                    domain: "AudioExtractor",
                    code: 23,
                    userInfo: [NSLocalizedDescriptionKey: "FFmpeg could not configure the audio decoder."]
                )
            }

            if avcodec_open2(codecContext, decoder, nil) < 0 {
                throw NSError(
                    domain: "AudioExtractor",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "无法打开音频解码器。"]
                )
            }

            let inputSampleRate = Int64(codecContext.pointee.sample_rate)
            guard inputSampleRate > 0 else {
                throw NSError(
                    domain: "AudioExtractor",
                    code: 16,
                    userInfo: [NSLocalizedDescriptionKey: "The decoded audio has no valid sample rate."]
                )
            }
            let outputSampleRate = Int64(targetSampleRate.rounded())

            let swr = swr_alloc()
            guard let swr = swr else {
                throw NSError(
                    domain: "AudioExtractor",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "分配重采样上下文失败。"]
                )
            }
            defer {
                var temp: OpaquePointer? = swr
                swr_free(&temp)
            }

            let rawSwr = UnsafeMutableRawPointer(swr)

            av_opt_set_chlayout(rawSwr, "in_chlayout", &codecContext.pointee.ch_layout, 0)
            av_opt_set_int(rawSwr, "in_sample_rate", Int64(codecContext.pointee.sample_rate), 0)
            av_opt_set_sample_fmt(rawSwr, "in_sample_fmt", codecContext.pointee.sample_fmt, 0)

            var outLayout = AVChannelLayout()
            av_channel_layout_default(&outLayout, 1)
            defer { av_channel_layout_uninit(&outLayout) }
            av_opt_set_chlayout(rawSwr, "out_chlayout", &outLayout, 0)
            av_opt_set_int(rawSwr, "out_sample_rate", Int64(targetSampleRate), 0)
            av_opt_set_sample_fmt(rawSwr, "out_sample_fmt", AV_SAMPLE_FMT_FLT, 0)

            if swr_init(swr) < 0 {
                throw NSError(
                    domain: "AudioExtractor",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "初始化音频重采样器失败。"]
                )
            }

            var samples: [Float] = []

            let packet = av_packet_alloc()
            let frame = av_frame_alloc()
            defer {
                var tempPacket = packet
                av_packet_free(&tempPacket)
                var tempFrame = frame
                av_frame_free(&tempFrame)
            }

            guard let packet = packet, let frame = frame else {
                throw NSError(
                    domain: "AudioExtractor",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "无法分配包或帧结构。"]
                )
            }

            var capacity = 4096
            var outBuffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            defer {
                outBuffer.deallocate()
            }

            func ensureOutputCapacity(_ requiredCapacity: Int) {
                guard requiredCapacity > capacity else { return }
                outBuffer.deallocate()
                capacity = max(requiredCapacity, min(Int(Int32.max), capacity * 2))
                outBuffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            }

            func appendConvertedFrame() throws {
                let delay = swr_get_delay(swr, inputSampleRate)
                let estimatedCount = av_rescale_rnd(
                    delay + Int64(frame.pointee.nb_samples),
                    outputSampleRate,
                    inputSampleRate,
                    AV_ROUND_UP
                )
                guard estimatedCount >= 0, estimatedCount <= Int64(Int32.max) else {
                    throw NSError(
                        domain: "AudioExtractor",
                        code: 17,
                        userInfo: [NSLocalizedDescriptionKey: "The resampled audio frame is too large."]
                    )
                }
                ensureOutputCapacity(max(1, Int(estimatedCount)))

                var outputData: [UnsafeMutablePointer<UInt8>?] = [
                    UnsafeMutablePointer<UInt8>(OpaquePointer(outBuffer)),
                    nil, nil, nil, nil, nil, nil, nil,
                ]
                let converted = withUnsafePointer(to: &frame.pointee.data) { pointer in
                    pointer.withMemoryRebound(
                        to: UnsafePointer<UInt8>?.self,
                        capacity: 8
                    ) { sourceData in
                        swr_convert(
                            swr,
                            &outputData,
                            Int32(capacity),
                            sourceData,
                            frame.pointee.nb_samples
                        )
                    }
                }
                guard converted >= 0 else {
                    throw NSError(
                        domain: "AudioExtractor",
                        code: 18,
                        userInfo: [NSLocalizedDescriptionKey: "FFmpeg failed to resample an audio frame."]
                    )
                }
                guard converted > 0 else { return }
                samples.append(
                    contentsOf: UnsafeBufferPointer(
                        start: outBuffer,
                        count: Int(converted)
                    )
                )
            }

            func receiveAvailableFrames() throws -> Int32 {
                while true {
                    av_frame_unref(frame)
                    let status = avcodec_receive_frame(codecContext, frame)
                    guard status >= 0 else { return status }
                    try appendConvertedFrame()
                }
            }

            while true {
                av_packet_unref(packet)
                guard av_read_frame(openedFormatContext, packet) >= 0 else { break }
                guard packet.pointee.stream_index == audioStreamIndex else { continue }

                var sendStatus = avcodec_send_packet(codecContext, packet)
                while sendStatus == -EAGAIN {
                    let receiveStatus = try receiveAvailableFrames()
                    guard receiveStatus == -EAGAIN else {
                        throw NSError(
                            domain: "AudioExtractor",
                            code: 19,
                            userInfo: [NSLocalizedDescriptionKey: "FFmpeg audio decoder stopped unexpectedly."]
                        )
                    }
                    sendStatus = avcodec_send_packet(codecContext, packet)
                }
                guard sendStatus >= 0 else {
                    throw NSError(
                        domain: "AudioExtractor",
                        code: 20,
                        userInfo: [NSLocalizedDescriptionKey: "FFmpeg rejected an audio packet."]
                    )
                }

                let receiveStatus = try receiveAvailableFrames()
                guard receiveStatus == -EAGAIN else {
                    throw NSError(
                        domain: "AudioExtractor",
                        code: 21,
                        userInfo: [NSLocalizedDescriptionKey: "FFmpeg audio decoding ended unexpectedly."]
                    )
                }
            }

            // Sending a nil packet releases delayed decoder frames.
            let drainStatus = avcodec_send_packet(codecContext, nil)
            if drainStatus >= 0 {
                _ = try receiveAvailableFrames()
            }

            // Flush every sample retained by the resampler's delay line.
            while true {
                let delayedCount = av_rescale_rnd(
                    swr_get_delay(swr, inputSampleRate),
                    outputSampleRate,
                    inputSampleRate,
                    AV_ROUND_UP
                )
                guard delayedCount > 0 else { break }
                guard delayedCount <= Int64(Int32.max) else {
                    throw NSError(
                        domain: "AudioExtractor",
                        code: 24,
                        userInfo: [NSLocalizedDescriptionKey: "The resampler delay is too large."]
                    )
                }
                ensureOutputCapacity(max(1, Int(delayedCount)))
                var outputData: [UnsafeMutablePointer<UInt8>?] = [
                    UnsafeMutablePointer<UInt8>(OpaquePointer(outBuffer)),
                    nil, nil, nil, nil, nil, nil, nil,
                ]
                let flushed = swr_convert(
                    swr,
                    &outputData,
                    Int32(capacity),
                    nil,
                    0
                )
                guard flushed > 0 else { break }
                samples.append(
                    contentsOf: UnsafeBufferPointer(
                        start: outBuffer,
                        count: Int(flushed)
                    )
                )
            }

            return samples
        }.value
    }

    /// Writes mono Float32 PCM to an AVFoundation-compatible WAV file.
    static func writeMonoWav(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard !samples.isEmpty,
            sampleRate.isFinite,
            (1...768_000).contains(sampleRate),
            samples.count <= Int(AVAudioFrameCount.max)
        else {
            throw NSError(
                domain: "AudioExtractor",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Invalid samples or sample rate for WAV output."]
            )
        }

        try? FileManager.default.removeItem(at: url)

        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw NSError(
                domain: "AudioExtractor",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 WAV 输出音频格式。"]
            )
        }

        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else {
            throw NSError(
                domain: "AudioExtractor",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 WAV 输出音频缓冲。"]
            )
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else {
            throw NSError(
                domain: "AudioExtractor",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "无法访问 WAV 输出音频缓冲。"]
            )
        }

        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channel.update(from: baseAddress, count: source.count)
        }

        let outputFile = try AVAudioFile(forWriting: url, settings: format.settings)
        try outputFile.write(from: buffer)
    }

    /// Writes mono samples as a 16-bit PCM WAV suitable for ASR services.
    static func writeMonoPCM16Wav(samples: [Float], sampleRate: Int, to url: URL) throws {
        let maximumSampleCount = (Int(UInt32.max) - 36) / MemoryLayout<Int16>.size
        guard !samples.isEmpty,
            (1...768_000).contains(sampleRate),
            samples.count <= maximumSampleCount
        else {
            throw NSError(
                domain: "AudioExtractor",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "Invalid samples or sample rate for PCM WAV output."]
            )
        }

        try? FileManager.default.removeItem(at: url)

        var data = Data()
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample / 8)
        let sampleRateValue = UInt32(sampleRate)
        let byteRate = sampleRateValue * UInt32(channels) * UInt32(bytesPerSample)
        let blockAlign = channels * UInt16(bytesPerSample)
        let pcmByteCount = UInt32(samples.count * bytesPerSample)
        let riffChunkSize = UInt32(36) + pcmByteCount

        func appendASCII(_ string: String) {
            data.append(Data(string.utf8))
        }

        func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
            var littleEndianValue = value.littleEndian
            withUnsafeBytes(of: &littleEndianValue) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendLittleEndian(riffChunkSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendLittleEndian(UInt32(16))
        appendLittleEndian(UInt16(1))
        appendLittleEndian(channels)
        appendLittleEndian(sampleRateValue)
        appendLittleEndian(byteRate)
        appendLittleEndian(blockAlign)
        appendLittleEndian(bitsPerSample)
        appendASCII("data")
        appendLittleEndian(pcmByteCount)

        data.reserveCapacity(data.count + Int(pcmByteCount))
        for sample in samples {
            let normalized = sample.isFinite ? max(-1.0, min(1.0, sample)) : 0.0
            let pcmValue: Int16
            if normalized <= -1.0 {
                pcmValue = Int16.min
            } else if normalized >= 1.0 {
                pcmValue = Int16.max
            } else {
                pcmValue = Int16((normalized * Float(Int16.max)).rounded())
            }
            appendLittleEndian(pcmValue)
        }

        try data.write(to: url, options: .atomic)
    }
}
