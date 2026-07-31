import AVFoundation
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample
import Libswscale

nonisolated let ffmpegExportNoPTS = Int64(bitPattern: 0x8000000000000000)

nonisolated private func ffmpegExportGetFormatCallback(
    _ codecContext: UnsafeMutablePointer<AVCodecContext>?,
    _ formats: UnsafePointer<AVPixelFormat>?
) -> AVPixelFormat {
    _ = codecContext
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
    private var softwareSwsContext: UnsafeMutablePointer<SwsContext>?
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var poolPixelFormat: OSType = 0
    private var reachedEOF = false
    private var packetNeedsSending = false
    private var sentDrainPacket = false

    private(set) var videoStreamIndex: Int32 = -1
    private(set) var storageSize: CGSize = .zero
    private(set) var sampleAspectRatio = CGSize(width: 1, height: 1)
    private(set) var frameRate: Double = 30
    private(set) var duration: Double = 0
    private(set) var audioStreamCount: Int = 0
    private(set) var sourceColorProfile: VideoColorProfile = .sdr709

    init(url: URL) throws {
        try open(url: url)
    }

    deinit {
        close()
    }

    func close() {
        if let softwareSwsContext {
            sws_freeContext(softwareSwsContext)
            self.softwareSwsContext = nil
        }
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
            av_frame_unref(frame)
            let receiveStatus = avcodec_receive_frame(codecContext, frame)
            if receiveStatus >= 0 {
                defer { av_frame_unref(frame) }
                guard let pixelBuffer = convertFrameToPixelBuffer(frame) else {
                    continue
                }
                let pts = framePTS(frame, formatContext: formatContext)
                return FFmpegVideoExportFrame(pixelBuffer: pixelBuffer, pts: pts)
            }

            if receiveStatus != -EAGAIN {
                if reachedEOF {
                    return nil
                }
                throw HardSubtitleVideoExportError.ffmpegDecodeFailed(
                    "avcodec_receive_frame(video) failed: \(receiveStatus)"
                )
            }

            if packetNeedsSending {
                let sendStatus = avcodec_send_packet(codecContext, packet)
                if sendStatus >= 0 {
                    packetNeedsSending = false
                    av_packet_unref(packet)
                } else if sendStatus != -EAGAIN {
                    packetNeedsSending = false
                    av_packet_unref(packet)
                    throw HardSubtitleVideoExportError.ffmpegDecodeFailed(
                        "avcodec_send_packet(video) failed: \(sendStatus)"
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
                return nil
            }

            av_packet_unref(packet)
            while true {
                let readStatus = av_read_frame(formatContext, packet)
                if readStatus < 0 {
                    reachedEOF = true
                    break
                }
                guard packet.pointee.stream_index == videoStreamIndex else {
                    av_packet_unref(packet)
                    continue
                }
                packetNeedsSending = true
                break
            }
        }
    }

    /// Seeks to the nearest preceding keyframe so ranged exports do not decode
    /// the entire file from zero. Exact range trimming still happens in the
    /// frame loop, preserving frame-accurate output.
    @discardableResult
    func seek(to seconds: Double) -> Bool {
        guard seconds.isFinite,
            seconds > 0,
            let formatContext,
            let codecContext,
            let stream = formatContext.pointee.streams[Int(videoStreamIndex)],
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
                videoStreamIndex,
                targetPTS,
                AVSEEK_FLAG_BACKWARD
            ) >= 0
        else {
            return false
        }

        avcodec_flush_buffers(codecContext)
        if let packet { av_packet_unref(packet) }
        if let frame { av_frame_unref(frame) }
        reachedEOF = false
        packetNeedsSending = false
        sentDrainPacket = false
        return true
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
            guard let stream = openedContext.pointee.streams[Int(index)],
                let codecParameters = stream.pointee.codecpar
            else { continue }
            switch codecParameters.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO where videoStreamIndex < 0:
                videoStreamIndex = Int32(index)
            case AVMEDIA_TYPE_AUDIO:
                audioStreamCount += 1
            default:
                break
            }
        }

        guard videoStreamIndex >= 0,
            let stream = openedContext.pointee.streams[Int(videoStreamIndex)],
            let codecParameters = stream.pointee.codecpar
        else {
            throw HardSubtitleVideoExportError.missingVideoTrack
        }

        sourceColorProfile = VideoColorProfile(
            ffmpegTransferRawValue: Int32(codecParameters.pointee.color_trc.rawValue)
        )
        storageSize = CGSize(
            width: Double(codecParameters.pointee.width), height: Double(codecParameters.pointee.height))
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

        guard avcodec_parameters_to_context(decoderContext, codecParameters) >= 0 else {
            throw HardSubtitleVideoExportError.ffmpegDecodeFailed(
                "Unable to configure the video decoder."
            )
        }
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
                canCreateVideoToolboxDevice()
            {
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
        let timestamp =
            frame.pointee.best_effort_timestamp != ffmpegExportNoPTS
            ? frame.pointee.best_effort_timestamp
            : frame.pointee.pts
        guard timestamp != ffmpegExportNoPTS,
            let stream = formatContext.pointee.streams[Int(videoStreamIndex)]
        else {
            return 0
        }
        let timeBase = stream.pointee.time_base
        return Double(timestamp) * Double(timeBase.num) / Double(timeBase.den)
    }

    private func convertFrameToPixelBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        let frameProfile = VideoColorProfile(
            ffmpegTransferRawValue: Int32(frame.pointee.color_trc.rawValue)
        )
        let colorProfile = frameProfile.isHDR ? frameProfile : sourceColorProfile

        if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue,
            let rawPixelBuffer = frame.pointee.data.3
        {
            let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(rawPixelBuffer).takeUnretainedValue()
            colorProfile.attachColorMetadata(
                to: pixelBuffer,
                copyingStaticHDRMetadataFrom: pixelBuffer
            )
            return pixelBuffer
        }

        let destinationPixelFormat = colorProfile.pixelFormat
        if pixelBufferPool == nil || poolWidth != width || poolHeight != height
            || poolPixelFormat != destinationPixelFormat
        {
            poolWidth = width
            poolHeight = height
            poolPixelFormat = destinationPixelFormat
            let poolAttributes: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: 4
            ]
            let bufferAttributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: destinationPixelFormat,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
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
            let pixelBuffer
        else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
            let uvPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else {
            return nil
        }

        softwareSwsContext = sws_getCachedContext(
            softwareSwsContext,
            Int32(width),
            Int32(height),
            AVPixelFormat(rawValue: frame.pointee.format),
            Int32(width),
            Int32(height),
            colorProfile.isHDR ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12,
            Int32(SWS_FAST_BILINEAR.rawValue),
            nil,
            nil,
            nil
        )
        guard let softwareSwsContext else { return nil }

        var destinationData: [UnsafeMutablePointer<UInt8>?] = [
            yPlane.assumingMemoryBound(to: UInt8.self),
            uvPlane.assumingMemoryBound(to: UInt8.self),
            nil,
            nil,
        ]
        var destinationLinesize: [Int32] = [
            Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)),
            Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)),
            0,
            0,
        ]

        _ = frame.withMemoryRebound(to: AVFrame.self, capacity: 1) { framePointer in
            let sourceData = withUnsafePointer(to: &framePointer.pointee.data) {
                $0.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { $0 }
            }
            let sourceLinesize = withUnsafePointer(to: &framePointer.pointee.linesize) {
                $0.withMemoryRebound(to: Int32.self, capacity: 8) { $0 }
            }
            return sws_scale(
                softwareSwsContext,
                sourceData,
                sourceLinesize,
                0,
                Int32(height),
                &destinationData,
                &destinationLinesize
            )
        }

        colorProfile.attachColorMetadata(to: pixelBuffer)
        return pixelBuffer
    }
}
