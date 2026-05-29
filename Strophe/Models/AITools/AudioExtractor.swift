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

nonisolated class AudioExtractor {
    
    /// 使用 FFmpeg 将本地音视频文件中的音频轨道提取并降采样为指定采样率的单声道 Float 数组
    /// 确保支持 MKV, WebM 容器格式及 Opus, FLAC, AAC, MP3, PCM 等所有格式音频解码
    /// - Parameters:
    ///   - url: 本地音视频文件路径
    ///   - targetSampleRate: 目标采样率 (例如 ASR 使用 16000, DeepFilterNet3 使用 48000)
    /// - Returns: 单声道 PCM Float 数组
    static func extract(from url: URL, targetSampleRate: Double = 16000.0) async throws -> [Float] {
        return try await Task.detached(priority: .userInitiated) {
            let path = url.path
            
            var formatContext: UnsafeMutablePointer<AVFormatContext>? = nil
            if avformat_open_input(&formatContext, path, nil, nil) < 0 {
                throw NSError(
                    domain: "AudioExtractor",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "FFmpeg 无法打开输入文件: \(url.lastPathComponent)"]
                )
            }
            defer {
                avformat_close_input(&formatContext)
            }
            
            if avformat_find_stream_info(formatContext, nil) < 0 {
                throw NSError(
                    domain: "AudioExtractor",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "无法获取媒体流信息。"]
                )
            }
            
            // 寻找最适合的音频流
            let audioStreamIndex = av_find_best_stream(formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
            guard audioStreamIndex >= 0 else {
                throw NSError(
                    domain: "AudioExtractor",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "媒体文件中未找到可用的音频轨道。"]
                )
            }
            
            let stream = formatContext!.pointee.streams[Int(audioStreamIndex)]!
            let codecpar = stream.pointee.codecpar!
            
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
            
            avcodec_parameters_to_context(codecContext, codecpar)
            
            if avcodec_open2(codecContext, decoder, nil) < 0 {
                throw NSError(
                    domain: "AudioExtractor",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "无法打开音频解码器。"]
                )
            }
            
            // 初始化音频重采样器 SwrContext
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
            
            // 输入通道布局、采样率、样本格式设置
            av_opt_set_chlayout(rawSwr, "in_chlayout", &codecContext.pointee.ch_layout, 0)
            av_opt_set_int(rawSwr, "in_sample_rate", Int64(codecContext.pointee.sample_rate), 0)
            av_opt_set_sample_fmt(rawSwr, "in_sample_fmt", codecContext.pointee.sample_fmt, 0)
            
            // 输出布局：单声道 (Mono)，目标采样率 (16000/48000)，Float 格式
            var outLayout = AVChannelLayout()
            av_channel_layout_default(&outLayout, 1)
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
            
            var samples = [Float]()
            
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
            
            // 预先分配转换所需的输出缓冲区（采用动态扩容方案，确保大容量/高采样率无损解码）
            var capacity = 4096
            var outBuffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            defer {
                outBuffer.deallocate()
            }
            
            // 开始循环解码包
            while av_read_frame(formatContext, packet) >= 0 {
                if packet.pointee.stream_index == audioStreamIndex {
                    if avcodec_send_packet(codecContext, packet) >= 0 {
                        while avcodec_receive_frame(codecContext, frame) >= 0 {
                            let delay = swr_get_delay(swr, Int64(codecContext.pointee.sample_rate))
                            let estimatedOutSamples = av_rescale_rnd(
                                delay + Int64(frame.pointee.nb_samples),
                                Int64(targetSampleRate),
                                Int64(codecContext.pointee.sample_rate),
                                AV_ROUND_UP
                            )
                            
                            // 动态扩容以防止任意音频包由于大帧或高采样率重采样被丢弃或溢出
                            if estimatedOutSamples > Int64(capacity) {
                                outBuffer.deallocate()
                                capacity = Int(estimatedOutSamples) * 2
                                outBuffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
                            }
                            
                            var outData: [UnsafeMutablePointer<UInt8>?] = [
                                UnsafeMutablePointer<UInt8>(OpaquePointer(outBuffer)),
                                nil, nil, nil, nil, nil, nil, nil
                            ]
                            
                            let srcData = withUnsafePointer(to: &frame.pointee.data) { ptr in
                                ptr.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { $0 }
                            }
                            
                            let converted = swr_convert(
                                swr,
                                &outData,
                                Int32(capacity),
                                srcData,
                                frame.pointee.nb_samples
                            )
                            
                            if converted > 0 {
                                let buffer = UnsafeBufferPointer(start: outBuffer, count: Int(converted))
                                samples.append(contentsOf: buffer)
                            }
                            av_frame_unref(frame)
                        }
                    }
                }
                av_packet_unref(packet)
            }
            
            // 冲刷重采样器的残留延迟缓冲
            var flushOutData: [UnsafeMutablePointer<UInt8>?] = [
                UnsafeMutablePointer<UInt8>(OpaquePointer(outBuffer)),
                nil, nil, nil, nil, nil, nil, nil
            ]
            let flushed = swr_convert(
                swr,
                &flushOutData,
                Int32(capacity),
                nil,
                0
            )
            if flushed > 0 {
                let buffer = UnsafeBufferPointer(start: outBuffer, count: Int(flushed))
                samples.append(contentsOf: buffer)
            }
            
            return samples
        }.value
    }
    
    /// 向后兼容接口
    static func extractUsingWhisperKit(from url: URL) async throws -> [Float] {
        return try await extract(from: url, targetSampleRate: 16000.0)
    }

    /// 将 FFmpeg 解码后的 Float32 单声道 PCM 写成 AVFoundation/CoreML 友好的 WAV 文件。
    static func writeMonoWav(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard !samples.isEmpty else {
            throw NSError(
                domain: "AudioExtractor",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "无法写入空音频到 WAV。"]
            )
        }

        try? FileManager.default.removeItem(at: url)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "AudioExtractor",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 WAV 输出音频格式。"]
            )
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
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
            channel.update(from: source.baseAddress!, count: samples.count)
        }

        let outputFile = try AVAudioFile(forWriting: url, settings: format.settings)
        try outputFile.write(from: buffer)
    }
}
