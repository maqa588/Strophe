import AVFoundation
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample
import Libswscale

nonisolated private let ffmpegExportNoPTS = Int64(bitPattern: 0x8000000000000000)

nonisolated(unsafe) private let ffmpegExportGetFormatCallback: @convention(c) (UnsafeMutablePointer<AVCodecContext>?, UnsafePointer<AVPixelFormat>?) -> AVPixelFormat = { _, formats in
    guard let formats else { return AV_PIX_FMT_NONE }
    var index = 0
    while formats[index] != AV_PIX_FMT_NONE {
        if formats[index] == AV_PIX_FMT_VIDEOTOOLBOX {
            return AV_PIX_FMT_VIDEOTOOLBOX
        }
        index += 1
    }
    return formats[0]
}

nonisolated struct FFmpegVideoExportFrame {
    let pixelBuffer: CVPixelBuffer
    let pts: Double
}

nonisolated final class FFmpegVideoExportVideoReader {
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var reachedEOF = false

    private(set) var videoStreamIndex: Int32 = -1
    private(set) var storageSize: CGSize = .zero
    private(set) var sampleAspectRatio = CGSize(width: 1, height: 1)
    private(set) var frameRate: Double = 30
    private(set) var duration: Double = 0

    init(url: URL) throws {
        try open(url: url)
    }

    deinit {
        close()
    }

    func close() {
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
        pixelBufferPool = nil
    }

    func nextFrame() throws -> FFmpegVideoExportFrame? {
        guard let formatContext, let codecContext, let packet, let frame else {
            return nil
        }

        while true {
            let receiveStatus = avcodec_receive_frame(codecContext, frame)
            if receiveStatus >= 0 {
                defer { av_frame_unref(frame) }
                guard let pixelBuffer = convertFrameToPixelBuffer(frame) else {
                    continue
                }
                let pts = framePTS(frame, formatContext: formatContext)
                return FFmpegVideoExportFrame(pixelBuffer: pixelBuffer, pts: pts)
            }

            if reachedEOF {
                return nil
            }

            av_packet_unref(packet)
            let readStatus = av_read_frame(formatContext, packet)
            if readStatus < 0 {
                reachedEOF = true
                avcodec_send_packet(codecContext, nil)
                continue
            }

            guard packet.pointee.stream_index == videoStreamIndex else {
                continue
            }

            let sendStatus = avcodec_send_packet(codecContext, packet)
            if sendStatus < 0 && sendStatus != -EAGAIN {
                throw HardSubtitleVideoExportError.ffmpegDecodeFailed("avcodec_send_packet(video) failed: \(sendStatus)")
            }
        }
    }

    private func open(url: URL) throws {
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&ctx, url.path, nil, nil) >= 0, let openedContext = ctx else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("无法打开输入文件。")
        }
        formatContext = openedContext

        guard avformat_find_stream_info(openedContext, nil) >= 0 else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("无法读取媒体流信息。")
        }

        for index in 0..<openedContext.pointee.nb_streams {
            guard let stream = openedContext.pointee.streams[Int(index)] else { continue }
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                videoStreamIndex = Int32(index)
                break
            }
        }

        guard videoStreamIndex >= 0,
              let stream = openedContext.pointee.streams[Int(videoStreamIndex)] else {
            throw HardSubtitleVideoExportError.missingVideoTrack
        }

        let codecParameters = stream.pointee.codecpar!
        storageSize = CGSize(width: Double(codecParameters.pointee.width), height: Double(codecParameters.pointee.height))
        sampleAspectRatio = resolvedSampleAspectRatio(stream: stream, codecParameters: codecParameters)
        frameRate = resolvedFrameRate(stream: stream)
        duration = resolvedDuration(formatContext: openedContext, stream: stream)

        guard let decoder = resolvedVideoDecoder(codecID: codecParameters.pointee.codec_id) else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("找不到可用的视频解码器。")
        }

        let decoderContext = avcodec_alloc_context3(decoder)
        guard let decoderContext else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("无法创建视频解码上下文。")
        }
        codecContext = decoderContext

        avcodec_parameters_to_context(decoderContext, codecParameters)
        decoderContext.pointee.get_format = ffmpegExportGetFormatCallback
        av_opt_set(decoderContext, "threads", "0", 0)
        configureVideoToolboxIfAvailable(decoder: decoder, codecContext: decoderContext)

        var opts: OpaquePointer?
        av_dict_set(&opts, "tilethreads", "0", 0)
        av_dict_set(&opts, "framethreads", "0", 0)
        av_dict_set(&opts, "threads", "0", 0)
        defer { av_dict_free(&opts) }

        guard avcodec_open2(decoderContext, decoder, &opts) >= 0 else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("无法打开视频解码器。")
        }

        packet = av_packet_alloc()
        frame = av_frame_alloc()
        guard packet != nil, frame != nil else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed("无法分配视频解码缓冲。")
        }
    }

    private func resolvedVideoDecoder(codecID: AVCodecID) -> UnsafePointer<AVCodec>? {
        if codecID == AV_CODEC_ID_AV1 {
            if let nativeAV1 = avcodec_find_decoder_by_name("av1"),
               decoderSupportsVideoToolbox(nativeAV1),
               canCreateVideoToolboxDevice() {
                return nativeAV1
            }
            if let dav1d = avcodec_find_decoder_by_name("libdav1d") {
                return dav1d
            }
        }
        return avcodec_find_decoder(codecID)
    }

    private func decoderSupportsVideoToolbox(_ decoder: UnsafePointer<AVCodec>) -> Bool {
        var index: Int32 = 0
        while let config = avcodec_get_hw_config(decoder, index) {
            if config.pointee.device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX {
                return true
            }
            index += 1
        }
        return false
    }

    private func canCreateVideoToolboxDevice() -> Bool {
        var hwDeviceContext: UnsafeMutablePointer<AVBufferRef>?
        let status = av_hwdevice_ctx_create(&hwDeviceContext, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0)
        if hwDeviceContext != nil {
            av_buffer_unref(&hwDeviceContext)
        }
        return status >= 0
    }

    private func configureVideoToolboxIfAvailable(
        decoder: UnsafePointer<AVCodec>,
        codecContext: UnsafeMutablePointer<AVCodecContext>
    ) {
        var index: Int32 = 0
        while let config = avcodec_get_hw_config(decoder, index) {
            if config.pointee.device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX {
                var hwDeviceContext: UnsafeMutablePointer<AVBufferRef>?
                if av_hwdevice_ctx_create(&hwDeviceContext, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 {
                    codecContext.pointee.hw_device_ctx = av_buffer_ref(hwDeviceContext)
                    av_buffer_unref(&hwDeviceContext)
                }
                return
            }
            index += 1
        }
    }

    private func resolvedFrameRate(stream: UnsafeMutablePointer<AVStream>) -> Double {
        let rates = [stream.pointee.avg_frame_rate, stream.pointee.r_frame_rate]
        for rate in rates where rate.den > 0 && rate.num > 0 {
            let value = Double(rate.num) / Double(rate.den)
            if value.isFinite, value > 0 {
                return value
            }
        }
        return 30
    }

    private func resolvedDuration(
        formatContext: UnsafeMutablePointer<AVFormatContext>,
        stream: UnsafeMutablePointer<AVStream>
    ) -> Double {
        if stream.pointee.duration != ffmpegExportNoPTS {
            let timeBase = stream.pointee.time_base
            return Double(stream.pointee.duration) * Double(timeBase.num) / Double(timeBase.den)
        }
        if formatContext.pointee.duration != ffmpegExportNoPTS {
            return Double(formatContext.pointee.duration) / Double(AV_TIME_BASE)
        }
        return 0
    }

    private func resolvedSampleAspectRatio(
        stream: UnsafeMutablePointer<AVStream>,
        codecParameters: UnsafeMutablePointer<AVCodecParameters>
    ) -> CGSize {
        let streamSAR = stream.pointee.sample_aspect_ratio
        if streamSAR.num > 0, streamSAR.den > 0 {
            return CGSize(width: Double(streamSAR.num), height: Double(streamSAR.den))
        }

        let codecSAR = codecParameters.pointee.sample_aspect_ratio
        if codecSAR.num > 0, codecSAR.den > 0 {
            return CGSize(width: Double(codecSAR.num), height: Double(codecSAR.den))
        }

        return CGSize(width: 1, height: 1)
    }

    private func framePTS(
        _ frame: UnsafeMutablePointer<AVFrame>,
        formatContext: UnsafeMutablePointer<AVFormatContext>
    ) -> Double {
        let timestamp = frame.pointee.best_effort_timestamp != ffmpegExportNoPTS
            ? frame.pointee.best_effort_timestamp
            : frame.pointee.pts
        guard timestamp != ffmpegExportNoPTS,
              let stream = formatContext.pointee.streams[Int(videoStreamIndex)] else {
            return 0
        }
        let timeBase = stream.pointee.time_base
        return Double(timestamp) * Double(timeBase.num) / Double(timeBase.den)
    }

    private func convertFrameToPixelBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)

        if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue,
           let rawPixelBuffer = frame.pointee.data.3 {
            return Unmanaged<CVPixelBuffer>.fromOpaque(rawPixelBuffer).takeUnretainedValue()
        }

        if pixelBufferPool == nil || poolWidth != width || poolHeight != height {
            poolWidth = width
            poolHeight = height
            let poolAttributes: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: 4
            ]
            let bufferAttributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
            CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                poolAttributes as CFDictionary,
                bufferAttributes as CFDictionary,
                &pixelBufferPool
            )
        }

        var pixelBuffer: CVPixelBuffer?
        guard let pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return nil
        }

        let swsContext = sws_getContext(
            Int32(width),
            Int32(height),
            AVPixelFormat(rawValue: frame.pointee.format),
            Int32(width),
            Int32(height),
            AV_PIX_FMT_NV12,
            Int32(SWS_FAST_BILINEAR.rawValue),
            nil,
            nil,
            nil
        )
        guard let swsContext else { return nil }
        defer { sws_freeContext(swsContext) }

        var destinationData: [UnsafeMutablePointer<UInt8>?] = [
            yPlane.assumingMemoryBound(to: UInt8.self),
            uvPlane.assumingMemoryBound(to: UInt8.self),
            nil,
            nil
        ]
        var destinationLinesize: [Int32] = [
            Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)),
            Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)),
            0,
            0
        ]

        _ = frame.withMemoryRebound(to: AVFrame.self, capacity: 1) { framePointer in
            let sourceData = withUnsafePointer(to: &framePointer.pointee.data) {
                $0.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { $0 }
            }
            let sourceLinesize = withUnsafePointer(to: &framePointer.pointee.linesize) {
                $0.withMemoryRebound(to: Int32.self, capacity: 8) { $0 }
            }
            return sws_scale(
                swsContext,
                sourceData,
                sourceLinesize,
                0,
                Int32(height),
                &destinationData,
                &destinationLinesize
            )
        }

        return pixelBuffer
    }
}

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
