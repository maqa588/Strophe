import Foundation
import AVFoundation
import Accelerate
import Combine
import CoreMedia
import Libavcodec
import Libavformat
import Libavutil
import Libswresample

struct WaveformBin: Codable {
    var peakPositive: Float
    var peakNegative: Float
    var rms: Float
}

@MainActor
class WaveformData: ObservableObject {
    @Published var levels: [Int: [WaveformBin]] = [:]
    @Published var isProcessing: Bool = false
    @Published var progress: Double = 0
    
    @Published var duration: Double = 0
    @Published var sampleRate: Double = 44100
}

@MainActor
class WaveformProcessor {
    static let shared = WaveformProcessor()
    
    static let zoomLevels: [Int] = [220, 880, 4410]
    
    func process(url: URL, completion: @escaping @MainActor (WaveformData) -> Void) {
        let data = WaveformData()
        
        Task.detached(priority: .userInitiated) {
            if let levels = await self.extractAndComputeBins(from: url, data: data) {
                await MainActor.run {
                    data.levels = levels
                }
            }
            
            await MainActor.run {
                completion(data)
            }
        }
    }
    
    private nonisolated func extractAndComputeBins(from url: URL, data: WaveformData) async -> [Int: [WaveformBin]]? {
        let isCompatible = await MainActor.run {
            return FormatDetector.shared.cachedResult(for: url)?.isAVFoundationCompatible 
                ?? ["mp4", "m4a", "mov", "mp3", "wav", "caf", "aif", "aiff"].contains(url.pathExtension.lowercased())
        }
        
        if isCompatible {
            if let bins = await extractViaAVFoundation(url: url, data: data) {
                return bins
            }
        }
        
        // Fallback to FFmpeg
        return extractViaFFmpeg(url: url, data: data)
    }
    
    // MARK: - AVFoundation-based waveform extraction (handles MP4/M4A/MP3/natively supported formats)
    private nonisolated func extractViaAVFoundation(url: URL, data: WaveformData) async -> [Int: [WaveformBin]]? {
        let resolvedURL = url.resolvingSymlinksInPath()
        let isScoped = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let asset = AVURLAsset(url: resolvedURL)
        
        guard let durationSecs = try? await asset.load(.duration).seconds, durationSecs > 0 else {
            print("⚠️ WaveformAVFoundation: Failed to load asset duration")
            return nil
        }
        
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let track = tracks.first else {
            print("⚠️ WaveformAVFoundation: No audio track found for \(resolvedURL.lastPathComponent)")
            return nil
        }
        
        guard let reader = try? AVAssetReader(asset: asset) else {
            print("⚠️ WaveformAVFoundation: Failed to create AVAssetReader")
            return nil
        }
        
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        
        guard reader.startReading() else {
            print("⚠️ WaveformAVFoundation: Failed to start reading")
            return nil
        }
        
        let outRate = 44100.0
        var allSamples: [Float] = []
        // Pre-reserve capacity to completely eliminate array resizing reallocations
        allSamples.reserveCapacity(Int(durationSecs * outRate) + 4096)
        
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { continue }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            
            let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc!)
            let channels = Int(asbd?.pointee.mChannelsPerFrame ?? 1)
            
            var length = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>? = nil
            
            // Access raw audio data memory directly without copying
            let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
            guard status == noErr, let rawPointer = dataPointer, totalLength > 0 else { continue }
            
            let sampleCount = totalLength / (4 * channels) // 32-bit float = 4 bytes
            guard sampleCount > 0 else { continue }
            
            let floatPtr = UnsafePointer<Float>(OpaquePointer(rawPointer))
            
            let startIdx = allSamples.count
            // Zero-allocation sequence expansion
            allSamples.append(contentsOf: repeatElement(0.0, count: sampleCount))
            
            allSamples.withUnsafeMutableBufferPointer { buffer in
                let destPtr = buffer.baseAddress!.advanced(by: startIdx)
                
                if channels == 2 {
                    // SIMD-accelerated stereo to mono downmix
                    vDSP_vadd(floatPtr, 2, floatPtr + 1, 2, destPtr, 1, vDSP_Length(sampleCount))
                    var half: Float = 0.5
                    vDSP_vsmul(destPtr, 1, &half, destPtr, 1, vDSP_Length(sampleCount))
                } else if channels == 1 {
                    // Vectorized block copy
                    memcpy(destPtr, floatPtr, sampleCount * 4)
                } else {
                    // Multi-channel fallback
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
        
        if reader.status == .completed {
            Task { @MainActor in
                data.duration = durationSecs
                data.sampleRate = outRate
            }
            
            print("✅ WaveformAVFoundation: extracted \(allSamples.count) mono samples from \(resolvedURL.lastPathComponent)")
            guard !allSamples.isEmpty else { return nil }
            
            return [
                220:  Self.computeBins(samples: allSamples, samplesPerBin: 220),
                880:  Self.computeBins(samples: allSamples, samplesPerBin: 880),
                4410: Self.computeBins(samples: allSamples, samplesPerBin: 4410)
            ]
        } else {
            print("⚠️ WaveformAVFoundation failed with status: \(reader.status.rawValue), error: \(String(describing: reader.error))")
            return nil
        }
    }
    
    // MARK: - FFmpeg-based waveform extraction (handles MKV/FLAC/Opus/all codecs)
    private nonisolated func extractViaFFmpeg(url: URL, data: WaveformData) -> [Int: [WaveformBin]]? {
        let resolvedURL = url.resolvingSymlinksInPath()
        let isScoped = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }
        
        var formatCtx: UnsafeMutablePointer<AVFormatContext>? = nil
        
        let openResult = avformat_open_input(&formatCtx, resolvedURL.path, nil, nil)
        guard openResult == 0, let ctx = formatCtx else {
            print("❌ WaveformFFmpeg: avformat_open_input failed: \(openResult) for \(resolvedURL.lastPathComponent)")
            return nil
        }
        defer { avformat_close_input(&formatCtx) }
        
        guard avformat_find_stream_info(ctx, nil) >= 0 else {
            print("❌ WaveformFFmpeg: avformat_find_stream_info failed")
            return nil
        }
        
        // Find best audio stream
        let audioIndex = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        guard audioIndex >= 0 else {
            print("❌ WaveformFFmpeg: no audio stream found in \(url.lastPathComponent)")
            return nil
        }
        
        let streamIndex = Int(audioIndex)
        let stream = ctx.pointee.streams[streamIndex]!
        let codecpar = stream.pointee.codecpar!
        
        guard let decoder = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            print("❌ WaveformFFmpeg: no decoder for codec \(codecpar.pointee.codec_id.rawValue)")
            return nil
        }
        
        let codecCtx = avcodec_alloc_context3(decoder)
        defer {
            var cc: UnsafeMutablePointer<AVCodecContext>? = codecCtx
            avcodec_free_context(&cc)
        }
        
        avcodec_parameters_to_context(codecCtx, codecpar)
        guard avcodec_open2(codecCtx, decoder, nil) >= 0, let cc = codecCtx else {
            print("❌ WaveformFFmpeg: avcodec_open2 failed")
            return nil
        }
        
        let durationSeconds: Double
        if ctx.pointee.duration != Int64(bitPattern: 0x8000000000000000) && ctx.pointee.duration > 0 {
            durationSeconds = Double(ctx.pointee.duration) / Double(AV_TIME_BASE)
        } else if stream.pointee.duration > 0 {
            let tb = stream.pointee.time_base
            durationSeconds = Double(stream.pointee.duration) * Double(tb.num) / Double(tb.den)
        } else {
            durationSeconds = 0
        }
        
        let nativeRate = Double(cc.pointee.sample_rate)
        let outRate: Int32 = 44100
        
        // Update duration/sampleRate on MainActor before processing
        let durCopy = durationSeconds
        Task { @MainActor in
            data.duration = durCopy
            data.sampleRate = Double(outRate)
        }
        
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
        av_opt_set_sample_fmt(rawSwr, "out_sample_fmt", AV_SAMPLE_FMT_FLT, 0) // interleaved float
        
        guard swr_init(swr) >= 0 else {
            print("❌ WaveformFFmpeg: swr_init failed")
            return nil
        }
        
        let frame = av_frame_alloc()
        let packet = av_packet_alloc()
        guard let frame = frame, let packet = packet else { return nil }
        defer {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
            var p: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&p)
        }
        
        var allSamples: [Float] = []
        allSamples.reserveCapacity(Int(Double(outRate) * max(1, durationSeconds)))
        
        while av_read_frame(ctx, packet) >= 0 {
            if packet.pointee.stream_index != Int32(streamIndex) {
                av_packet_unref(packet)
                continue
            }
            
            if avcodec_send_packet(cc, packet) < 0 {
                av_packet_unref(packet)
                continue
            }
            av_packet_unref(packet)
            
            while avcodec_receive_frame(cc, frame) >= 0 {
                let maxOutSamples = Int(swr_get_delay(swr, Int64(nativeRate)) + Int64(frame.pointee.nb_samples)) + 512
                
                // Allocate output buffer (interleaved float stereo)
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
                    // Interleaved stereo float → mix to mono
                    let sampleCount = Int(converted) * 2
                    let floatBuf = UnsafeBufferPointer(start: rawOut.withMemoryRebound(to: Float.self, capacity: sampleCount) { $0 }, count: sampleCount)
                    for i in stride(from: 0, to: floatBuf.count - 1, by: 2) {
                        allSamples.append((floatBuf[i] + floatBuf[i + 1]) * 0.5)
                    }
                }
                
                av_frame_unref(frame)
            }
        }
        
        // Flush swr remainder
        var flushOut: UnsafeMutablePointer<UInt8>? = nil
        let flushLine = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        defer { flushLine.deallocate() }
        av_samples_alloc(&flushOut, flushLine, 2, 4096, AV_SAMPLE_FMT_FLT, 0)
        if let rawFlush = flushOut {
            var mutableFlush: UnsafeMutablePointer<UInt8>? = rawFlush
            let flushed = withUnsafeMutablePointer(to: &mutableFlush) { outPtrPtr -> Int32 in
                var nilIn: UnsafePointer<UInt8>? = nil
                return withUnsafePointer(to: &nilIn) { inPtrPtr in
                    swr_convert(swr, outPtrPtr, 4096, inPtrPtr, 0)
                }
            }
            if flushed > 0 {
                let flushCount = Int(flushed) * 2
                let floatBuf = UnsafeBufferPointer(start: rawFlush.withMemoryRebound(to: Float.self, capacity: flushCount) { $0 }, count: flushCount)
                for i in stride(from: 0, to: floatBuf.count - 1, by: 2) {
                    allSamples.append((floatBuf[i] + floatBuf[i + 1]) * 0.5)
                }
            }
            av_freep(&flushOut)
        }
        
        print("✅ WaveformFFmpeg: extracted \(allSamples.count) mono samples from \(url.lastPathComponent)")
        
        guard !allSamples.isEmpty else { return nil }
        
        return [
            220:  Self.computeBins(samples: allSamples, samplesPerBin: 220),
            880:  Self.computeBins(samples: allSamples, samplesPerBin: 880),
            4410: Self.computeBins(samples: allSamples, samplesPerBin: 4410)
        ]
    }
    
    nonisolated static private func computeBins(samples: [Float], samplesPerBin: Int) -> [WaveformBin] {
        let binCount = samples.count / samplesPerBin
        var bins: [WaveformBin] = []
        bins.reserveCapacity(binCount)
        
        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            
            for i in 0..<binCount {
                let start = i * samplesPerBin
                let count = samplesPerBin
                let ptr = baseAddress.advanced(by: start)
                
                var peakPos: Float = 0
                vDSP_maxv(ptr, 1, &peakPos, vDSP_Length(count))
                
                var peakNeg: Float = 0
                vDSP_minv(ptr, 1, &peakNeg, vDSP_Length(count))
                
                var rms: Float = 0
                vDSP_rmsqv(ptr, 1, &rms, vDSP_Length(count))
                
                bins.append(WaveformBin(peakPositive: max(0, peakPos), peakNegative: min(0, peakNeg), rms: rms))
            }
        }
        
        return bins
    }
}
