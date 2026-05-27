//
//  WaveformProcessor.swift
//  Strophe
//
//  Created by maqa on 2026/5/18.
//

import Foundation
import AVFoundation
import Accelerate
import CoreMedia
import Libavcodec
import Libavformat
import Libavutil
import Libswresample

@MainActor
class WaveformProcessor {
    static let shared = WaveformProcessor()
    
    static let zoomLevels: [Int] = [220, 880, 4410]
    
    private init() {
        av_log_set_level(8) // Set global FFmpeg log level to AV_LOG_FATAL to silence decoding warning/error spam
    }
    
    func process(url: URL, completion: @escaping @MainActor (WaveformData) -> Void) {
        let data = WaveformData()
        data.isProcessing = true
        
        Task.detached(priority: .userInitiated) {
            if let metadata = await self.probeMetadata(url: url) {
                await MainActor.run {
                    data.initialize(duration: metadata.duration, sampleRate: metadata.sampleRate, url: url)
                    data.isProcessing = false
                    completion(data)
                }
            } else {
                await MainActor.run {
                    data.isProcessing = false
                    completion(data)
                }
            }
        }
    }
    
    private nonisolated func probeMetadata(url: URL) async -> (duration: Double, sampleRate: Double)? {
        let resolvedURL = url.resolvingSymlinksInPath()
        let isScoped = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let isCompatible = await MainActor.run {
            return FormatDetector.shared.cachedResult(for: url)?.isAVFoundationCompatible 
                ?? ["mp4", "m4a", "mov", "mp3", "wav", "caf", "aif", "aiff"].contains(url.pathExtension.lowercased())
        }
        
        if isCompatible {
            let asset = AVURLAsset(url: resolvedURL)
            if let durationSecs = try? await asset.load(.duration).seconds, durationSecs > 0 {
                return (durationSecs, 44100.0)
            }
        }
        
        // Fast path: use FFmpeg format context to instantly read headers (duration is in metadata)
        var formatCtx: UnsafeMutablePointer<AVFormatContext>? = nil
        let openResult = avformat_open_input(&formatCtx, resolvedURL.path, nil, nil)
        guard openResult == 0, let ctx = formatCtx else { return nil }
        defer { avformat_close_input(&formatCtx) }
        
        guard avformat_find_stream_info(ctx, nil) >= 0 else { return nil }
        
        let audioIndex = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        guard audioIndex >= 0 else { return nil }
        
        let streamIndex = Int(audioIndex)
        let stream = ctx.pointee.streams[streamIndex]!
        
        let durationSeconds: Double
        if ctx.pointee.duration != Int64(bitPattern: 0x8000000000000000) && ctx.pointee.duration > 0 {
            durationSeconds = Double(ctx.pointee.duration) / Double(AV_TIME_BASE)
        } else if stream.pointee.duration > 0 {
            let tb = stream.pointee.time_base
            durationSeconds = Double(stream.pointee.duration) * Double(tb.num) / Double(tb.den)
        } else {
            durationSeconds = 0
        }
        
        let sampleRate = 44100.0 // Unified sampleRate to 44100.0 for consistent math
        return (durationSeconds, sampleRate)
    }
    
    nonisolated func decodeChunk(url: URL, startTime: Double, duration: Double) async -> [Float]? {
        let isCompatible = await MainActor.run {
            return FormatDetector.shared.cachedResult(for: url)?.isAVFoundationCompatible 
                ?? ["mp4", "m4a", "mov", "mp3", "wav", "caf", "aif", "aiff"].contains(url.pathExtension.lowercased())
        }
        
        if isCompatible {
            if let samples = await decodeChunkViaAVFoundation(url: url, startTime: startTime, duration: duration) {
                return samples
            }
        }
        
        return decodeChunkViaFFmpeg(url: url, startTime: startTime, duration: duration)
    }
    
    // MARK: - Continuous AVFoundation Decoding
    nonisolated func decodeEntireFileViaAVFoundation(
        url: URL,
        onProgress: @Sendable @escaping (_ samples: [Float], _ chunkStart: Double, _ chunkDur: Double) -> Void
    ) async -> Bool {
        let resolvedURL = url.resolvingSymlinksInPath()
        let isScoped = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let asset = AVURLAsset(url: resolvedURL)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let track = tracks.first else { return false }
              
        guard let reader = try? AVAssetReader(asset: asset) else { return false }
        
        let outRate = 44100.0
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: outRate, // Resample natively to unified 44100Hz
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        
        guard reader.startReading() else { return false }
        
        var accumulatedSamples: [Float] = []
        let chunkSizeSamples = 2646000 // 60 seconds of audio at 44100Hz
        accumulatedSamples.reserveCapacity(chunkSizeSamples)
        
        var currentChunkIndex = 0
        
        while reader.status == .reading {
            if Task.isCancelled {
                reader.cancelReading()
                return false
            }
            
            guard let sampleBuffer = output.copyNextSampleBuffer() else { continue }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            
            let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc!)
            let channels = Int(asbd?.pointee.mChannelsPerFrame ?? 1)
            
            var length = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>? = nil
            
            let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
            guard status == noErr, let rawPointer = dataPointer, totalLength > 0 else { continue }
            
            let sampleCount = totalLength / (4 * channels)
            guard sampleCount > 0 else { continue }
            
            let floatPtr = UnsafePointer<Float>(OpaquePointer(rawPointer))
            let startIdx = accumulatedSamples.count
            accumulatedSamples.append(contentsOf: repeatElement(0.0, count: sampleCount))
            
            accumulatedSamples.withUnsafeMutableBufferPointer { buffer in
                let destPtr = buffer.baseAddress!.advanced(by: startIdx)
                if channels == 2 {
                    vDSP_vadd(floatPtr, 2, floatPtr + 1, 2, destPtr, 1, vDSP_Length(sampleCount))
                    var half: Float = 0.5
                    vDSP_vsmul(destPtr, 1, &half, destPtr, 1, vDSP_Length(sampleCount))
                } else if channels == 1 {
                    memcpy(destPtr, floatPtr, sampleCount * 4)
                } else {
                    for i in 0..<sampleCount {
                        var sum: Float = 0
                        for c in 0..<channels {
                            sum += floatPtr[i * channels + c]
                        }
                        destPtr[i] = sum / Float(channels)
                    }
                }
            }
            
            // Publish chunks in 60-second batches progressively
            while accumulatedSamples.count >= chunkSizeSamples {
                if Task.isCancelled {
                    reader.cancelReading()
                    return false
                }
                
                let chunk = Array(accumulatedSamples[0..<chunkSizeSamples])
                accumulatedSamples.removeFirst(chunkSizeSamples)
                
                let chunkStart = Double(currentChunkIndex) * 60.0
                onProgress(chunk, chunkStart, 60.0)
                currentChunkIndex += 1
            }
        }
        
        // Publish remaining samples at the end
        if !accumulatedSamples.isEmpty && !Task.isCancelled {
            let chunkDur = Double(accumulatedSamples.count) / outRate
            let chunkStart = Double(currentChunkIndex) * 60.0
            onProgress(accumulatedSamples, chunkStart, chunkDur)
        }
        
        return reader.status == .completed
    }
    
    // MARK: - Segmented AVFoundation Decoding
    private nonisolated func decodeChunkViaAVFoundation(url: URL, startTime: Double, duration: Double) async -> [Float]? {
        let resolvedURL = url.resolvingSymlinksInPath()
        let isScoped = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let asset = AVURLAsset(url: resolvedURL)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let track = tracks.first else { return nil }
              
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        
        let outRate = 44100.0
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: outRate, // Ensure AVAssetReader performs high-quality resampling to a unified 44100Hz!
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        
        // Target the specific time range inside the reader
        let rangeStart = CMTime(seconds: startTime, preferredTimescale: 600)
        let rangeDuration = CMTime(seconds: duration, preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: rangeStart, duration: rangeDuration)
        
        guard reader.startReading() else { return nil }
        
        var chunkSamples: [Float] = []
        chunkSamples.reserveCapacity(Int(duration * outRate) + 4096)
        
        while reader.status == .reading {
            if Task.isCancelled {
                reader.cancelReading()
                return nil
            }
            guard let sampleBuffer = output.copyNextSampleBuffer() else { continue }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            
            let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc!)
            let channels = Int(asbd?.pointee.mChannelsPerFrame ?? 1)
            
            var length = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>? = nil
            
            let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
            guard status == noErr, let rawPointer = dataPointer, totalLength > 0 else { continue }
            
            let sampleCount = totalLength / (4 * channels)
            guard sampleCount > 0 else { continue }
            
            let floatPtr = UnsafePointer<Float>(OpaquePointer(rawPointer))
            let startIdx = chunkSamples.count
            chunkSamples.append(contentsOf: repeatElement(0.0, count: sampleCount))
            
            chunkSamples.withUnsafeMutableBufferPointer { buffer in
                let destPtr = buffer.baseAddress!.advanced(by: startIdx)
                if channels == 2 {
                    vDSP_vadd(floatPtr, 2, floatPtr + 1, 2, destPtr, 1, vDSP_Length(sampleCount))
                    var half: Float = 0.5
                    vDSP_vsmul(destPtr, 1, &half, destPtr, 1, vDSP_Length(sampleCount))
                } else if channels == 1 {
                    memcpy(destPtr, floatPtr, sampleCount * 4)
                } else {
                    for i in 0..<sampleCount {
                        var sum: Float = 0
                        for c in 0..<channels {
                            sum += floatPtr[i * channels + c]
                        }
                        destPtr[i] = sum / Float(channels)
                    }
                }
            }
        }
        
        return reader.status == .completed ? chunkSamples : nil
    }
    
    // MARK: - Segmented FFmpeg Decoding
    private nonisolated func decodeChunkViaFFmpeg(url: URL, startTime: Double, duration: Double) -> [Float]? {
        let resolvedURL = url.resolvingSymlinksInPath()
        let isScoped = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }
        
        var formatCtx: UnsafeMutablePointer<AVFormatContext>? = nil
        let openResult = avformat_open_input(&formatCtx, resolvedURL.path, nil, nil)
        guard openResult == 0, let ctx = formatCtx else { return nil }
        defer { avformat_close_input(&formatCtx) }
        
        guard avformat_find_stream_info(ctx, nil) >= 0 else { return nil }
        
        let audioIndex = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        guard audioIndex >= 0 else { return nil }
        
        let streamIndex = Int(audioIndex)
        let stream = ctx.pointee.streams[streamIndex]!
        let codecpar = stream.pointee.codecpar!
        
        guard let decoder = avcodec_find_decoder(codecpar.pointee.codec_id) else { return nil }
        
        let codecCtx = avcodec_alloc_context3(decoder)
        defer {
            var cc: UnsafeMutablePointer<AVCodecContext>? = codecCtx
            avcodec_free_context(&cc)
        }
        
        avcodec_parameters_to_context(codecCtx, codecpar)
        guard avcodec_open2(codecCtx, decoder, nil) >= 0, let cc = codecCtx else { return nil }
        
        let nativeRate = Double(cc.pointee.sample_rate)
        let outRate: Int32 = 44100
        
        // Fast seek to the start time of the chunk
        let tb = stream.pointee.time_base
        let targetPts = Int64(startTime * Double(tb.den) / Double(tb.num))
        av_seek_frame(ctx, Int32(streamIndex), targetPts, AVSEEK_FLAG_BACKWARD)
        avcodec_flush_buffers(cc)
        
        // Setup libswresample to convert to interleaved float32 stereo at 44100 Hz
        let swr = swr_alloc()
        guard let swr = swr else { return nil }
        defer { var s: OpaquePointer? = swr; swr_free(&s) }
        
        let rawSwr = UnsafeMutableRawPointer(swr)
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, 2)
        
        av_opt_set_chlayout(rawSwr, "in_chlayout", &cc.pointee.ch_layout, 0)
        av_opt_set_int(rawSwr, "in_sample_rate", Int64(cc.pointee.sample_rate), 0)
        av_opt_set_sample_fmt(rawSwr, "in_sample_fmt", cc.pointee.sample_fmt, 0)
        av_opt_set_chlayout(rawSwr, "out_chlayout", &outLayout, 0)
        av_opt_set_int(rawSwr, "out_sample_rate", Int64(outRate), 0)
        av_opt_set_sample_fmt(rawSwr, "out_sample_fmt", AV_SAMPLE_FMT_FLT, 0)
        
        guard swr_init(swr) >= 0 else { return nil }
        
        let frame = av_frame_alloc()
        let packet = av_packet_alloc()
        guard let frame = frame, let packet = packet else { return nil }
        defer {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
            var p: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&p)
        }
        
        var chunkSamples: [Float] = []
        let estimatedSamplesCount = Int(Double(outRate) * duration)
        chunkSamples.reserveCapacity(estimatedSamplesCount + 44100)
        
        var currentPtsSeconds: Double = startTime
        let endTime = startTime + duration
        
        while av_read_frame(ctx, packet) >= 0 {
            if Task.isCancelled {
                av_packet_unref(packet)
                return nil
            }
            
            if packet.pointee.stream_index != Int32(streamIndex) {
                av_packet_unref(packet)
                continue
            }
            
            if packet.pointee.pts != Int64(bitPattern: 0x8000000000000000) {
                currentPtsSeconds = Double(packet.pointee.pts) * Double(tb.num) / Double(tb.den)
                if currentPtsSeconds > endTime {
                    av_packet_unref(packet)
                    break
                }
            }
            
            if avcodec_send_packet(cc, packet) < 0 {
                av_packet_unref(packet)
                continue
            }
            av_packet_unref(packet)
            
            while avcodec_receive_frame(cc, frame) >= 0 {
                if Task.isCancelled {
                    av_frame_unref(frame)
                    return nil
                }
                let maxOutSamples = Int(swr_get_delay(swr, Int64(nativeRate)) + Int64(frame.pointee.nb_samples)) + 512
                
                var outData: UnsafeMutablePointer<UInt8>? = nil
                let linesize = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
                defer {
                    if outData != nil { av_freep(&outData) }
                    linesize.deallocate()
                }
                av_samples_alloc(&outData, linesize, 2, Int32(maxOutSamples), AV_SAMPLE_FMT_FLT, 0)
                
                let converted: Int32
                if let rawOut = outData {
                    var mutableOut: UnsafeMutablePointer<UInt8>? = rawOut
                    let srcData = withUnsafePointer(to: &frame.pointee.data) { ptr in
                        ptr.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { $0 }
                    }
                    converted = withUnsafeMutablePointer(to: &mutableOut) { outPtrPtr in
                        swr_convert(swr, outPtrPtr, Int32(maxOutSamples), srcData, Int32(frame.pointee.nb_samples))
                    }
                } else {
                    converted = 0
                }
                
                if converted > 0, let rawOut = outData {
                    let sampleCount = Int(converted) * 2
                    let floatBuf = UnsafeBufferPointer(start: rawOut.withMemoryRebound(to: Float.self, capacity: sampleCount) { $0 }, count: sampleCount)
                    
                    var framePtsSeconds = currentPtsSeconds
                    if frame.pointee.pts != Int64(bitPattern: 0x8000000000000000) {
                        framePtsSeconds = Double(frame.pointee.pts) * Double(tb.num) / Double(tb.den)
                    }
                    
                    if framePtsSeconds >= startTime {
                        for i in stride(from: 0, to: floatBuf.count - 1, by: 2) {
                            chunkSamples.append((floatBuf[i] + floatBuf[i + 1]) * 0.5)
                        }
                    }
                }
                av_frame_unref(frame)
            }
        }
        
        return chunkSamples
    }
    
    nonisolated static internal func computeBins(samples: [Float], expectedBinCount: Int) -> [WaveformBin] {
        guard expectedBinCount > 0 && !samples.isEmpty else { return [] }
        var bins: [WaveformBin] = []
        bins.reserveCapacity(expectedBinCount)
        
        let samplesPerBin = Double(samples.count) / Double(expectedBinCount)
        
        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            
            for i in 0..<expectedBinCount {
                let start = Int(Double(i) * samplesPerBin)
                let nextStart = Int(Double(i + 1) * samplesPerBin)
                let count = max(1, nextStart - start)
                
                let safeStart = min(samples.count - 1, max(0, start))
                let safeCount = min(samples.count - safeStart, count)
                
                guard safeCount > 0 else {
                    bins.append(WaveformBin(peakPositive: 0, peakNegative: 0, rms: 0))
                    continue
                }
                
                let ptr = baseAddress.advanced(by: safeStart)
                
                var peakPos: Float = 0
                vDSP_maxv(ptr, 1, &peakPos, vDSP_Length(safeCount))
                
                var peakNeg: Float = 0
                vDSP_minv(ptr, 1, &peakNeg, vDSP_Length(safeCount))
                
                var rms: Float = 0
                vDSP_rmsqv(ptr, 1, &rms, vDSP_Length(safeCount))
                
                bins.append(WaveformBin(peakPositive: max(0, peakPos), peakNegative: min(0, peakNeg), rms: rms))
            }
        }
        
        return bins
    }
}
