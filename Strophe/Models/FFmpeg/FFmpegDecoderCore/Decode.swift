import Foundation
import CoreVideo
import QuartzCore
import Libavcodec
import Libavformat
import Libavutil
import Libswscale
import Libswresample

// MARK: - Low-Level FFmpeg Logic
extension FFmpegDecoderCore {

    func openInput(url: URL) -> Bool {
        let path = url.path
        var ctx: UnsafeMutablePointer<AVFormatContext>? = nil
        let isRemote = FormatDetector.isRemoteNetworkVolume(url)

        if avformat_open_input(&ctx, path, nil, nil) < 0 {
            print("❌ FFmpegEngine: Failed to open format context input")
            return false
        }
        self.formatContext = ctx

        if avformat_find_stream_info(ctx, nil) < 0 {
            print("❌ FFmpegEngine: Failed to find stream info")
            return false
        }

        // Find stream indices
        for i in 0..<ctx!.pointee.nb_streams {
            let stream = ctx!.pointee.streams[Int(i)]!
            let mediaType = stream.pointee.codecpar.pointee.codec_type

            if mediaType == AVMEDIA_TYPE_VIDEO && videoStreamIndex < 0 {
                videoStreamIndex = Int32(i)
            } else if mediaType == AVMEDIA_TYPE_AUDIO && audioStreamIndex < 0 {
                audioStreamIndex = Int32(i)
            }
        }

        guard videoStreamIndex >= 0 else {
            print("❌ FFmpegEngine: No video stream found")
            return false
        }

        // Initialize Video Decoder
        let videoStream = ctx!.pointee.streams[Int(videoStreamIndex)]!
        let vCodecpar = videoStream.pointee.codecpar!

        self.videoFrameSize = CGSize(width: Double(vCodecpar.pointee.width), height: Double(vCodecpar.pointee.height))

        if videoStream.pointee.avg_frame_rate.den > 0 {
            self.videoFPS = Double(videoStream.pointee.avg_frame_rate.num) / Double(videoStream.pointee.avg_frame_rate.den)
        }
        self.maxVideoQueueCapacity = FFmpegPlaybackTuning.queueCapacity(
            fps: videoFPS,
            width: Int(vCodecpar.pointee.width),
            height: Int(vCodecpar.pointee.height),
            isRemote: isRemote
        )
        if isRemote {
            print("🌐 FFmpeg SMB buffer: \(maxVideoQueueCapacity) decoded frames")
        }

        if ctx!.pointee.duration != FFmpegDecoderCore.AV_NOPTS_VALUE {
            self.videoDuration = Double(ctx!.pointee.duration) / Double(AV_TIME_BASE)
        }

        var resolvedDecoder = avcodec_find_decoder(vCodecpar.pointee.codec_id)
        var useVTForAV1 = false

        if vCodecpar.pointee.codec_id == AV_CODEC_ID_AV1 {
            // Try native AV1 decoder first, which supports VideoToolbox hwaccel
            if let nativeAV1 = avcodec_find_decoder_by_name("av1") {
                // Check if it has a VideoToolbox hw_config
                var i: Int32 = 0
                var hasVTConfig = false
                while let config = avcodec_get_hw_config(nativeAV1, i) {
                    if config.pointee.device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX {
                        hasVTConfig = true
                        break
                    }
                    i += 1
                }

                if hasVTConfig {
                    // Try to create the VideoToolbox device context to verify physical/OS support
                    var hwDeviceCtx: UnsafeMutablePointer<AVBufferRef>? = nil
                    if av_hwdevice_ctx_create(&hwDeviceCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 {
                        // Success! We can use native AV1 with VideoToolbox hardware acceleration
                        av_buffer_unref(&hwDeviceCtx)
                        resolvedDecoder = nativeAV1
                        useVTForAV1 = true
                        print("🎬 FFmpegEngine: Selected native AV1 decoder with VideoToolbox hardware acceleration.")
                    } else {
                        print("ℹ️ FFmpegEngine: Native AV1 decoder has VideoToolbox config but hardware creation failed (likely M1/M2 or OS limitation). Falling back to software libdav1d.")
                    }
                } else {
                    print("ℹ️ FFmpegEngine: Native AV1 decoder does not support VideoToolbox in this FFmpeg build. Falling back to software libdav1d.")
                }
            }

            if !useVTForAV1 {
                // Fallback to high-performance software libdav1d
                if let dav1d = avcodec_find_decoder_by_name("libdav1d") {
                    resolvedDecoder = dav1d
                    print("🎬 FFmpegEngine: Selected software libdav1d decoder for AV1.")
                }
            }
        }

        guard let vDecoder = resolvedDecoder else {
            print("❌ FFmpegEngine: Failed to find video decoder")
            return false
        }

        let vCtx = avcodec_alloc_context3(vDecoder)
        self.videoCodecContext = vCtx
        av_opt_set(vCtx, "threads", FFmpegPlaybackTuning.codecThreads, 0)
        avcodec_parameters_to_context(vCtx, vCodecpar)

        // 绑定协商回调以强制开启 VideoToolbox 输出
        vCtx!.pointee.get_format = getFormatCallback

        // Enable hardware accelerated VideoToolbox decoding if supported
        var i: Int32 = 0
        var foundConfig = false
        while let config = avcodec_get_hw_config(vDecoder, i) {
            if config.pointee.device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX {
                var hwDeviceCtx: UnsafeMutablePointer<AVBufferRef>? = nil
                if av_hwdevice_ctx_create(&hwDeviceCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 {
                    vCtx!.pointee.hw_device_ctx = av_buffer_ref(hwDeviceCtx)
                    av_buffer_unref(&hwDeviceCtx)
                    print("✅ VideoToolbox hwaccel enabled via config index \(i)")
                    foundConfig = true
                }
                break
            }
            i += 1
        }

        if !foundConfig {
            print("⚠️ Warning: VideoToolbox hw_config not found for this decoder.")
        }

        var opts: OpaquePointer? = nil
        av_dict_set(&opts, "tilethreads", FFmpegPlaybackTuning.tileThreads, 0)
        av_dict_set(&opts, "framethreads", FFmpegPlaybackTuning.frameThreads, 0)
        av_dict_set(&opts, "threads", FFmpegPlaybackTuning.codecThreads, 0)

        if avcodec_open2(vCtx, vDecoder, &opts) < 0 {
            print("❌ FFmpegEngine: Failed to open video codec")
            av_dict_free(&opts)
            return false
        }
        av_dict_free(&opts)

        // Initialize Audio Decoder (if present)
        if audioStreamIndex >= 0 {
            let audioStream = ctx!.pointee.streams[Int(audioStreamIndex)]!
            let aCodecpar = audioStream.pointee.codecpar!

            if let aDecoder = avcodec_find_decoder(aCodecpar.pointee.codec_id) {
                let aCtx = avcodec_alloc_context3(aDecoder)
                self.audioCodecContext = aCtx
                avcodec_parameters_to_context(aCtx, aCodecpar)

                if avcodec_open2(aCtx, aDecoder, nil) >= 0 {
                    setupAudioResampler()
                }
            }
        }

        return true
    }

    func setupAudioResampler() {
        guard let aCtx = audioCodecContext else { return }

        let swr = swr_alloc()
        self.swrContext = swr

        guard let swr = swr else { return }
        let rawSwr = UnsafeMutableRawPointer(swr)

        av_opt_set_chlayout(rawSwr, "in_chlayout", &aCtx.pointee.ch_layout, 0)
        av_opt_set_int(rawSwr, "in_sample_rate", Int64(aCtx.pointee.sample_rate), 0)
        av_opt_set_sample_fmt(rawSwr, "in_sample_fmt", aCtx.pointee.sample_fmt, 0)

        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, 2)
        av_opt_set_chlayout(rawSwr, "out_chlayout", &outLayout, 0)
        av_opt_set_int(rawSwr, "out_sample_rate", 44100, 0)
        av_opt_set_sample_fmt(rawSwr, "out_sample_fmt", AV_SAMPLE_FMT_FLTP, 0)

        swr_init(swr)
    }

    func rebuildVideoCodecContext() {
        guard let ctx = formatContext, videoStreamIndex >= 0 else { return }
        guard videoCodecContext != nil else { return }

        let stream = ctx.pointee.streams[Int(videoStreamIndex)]!
        let codecpar = stream.pointee.codecpar!

        var resolvedDecoder = avcodec_find_decoder(codecpar.pointee.codec_id)
        var useVTForAV1 = false

        if codecpar.pointee.codec_id == AV_CODEC_ID_AV1 {
            // Try native AV1 decoder first, which supports VideoToolbox hwaccel
            if let nativeAV1 = avcodec_find_decoder_by_name("av1") {
                // Check if it has a VideoToolbox hw_config
                var i: Int32 = 0
                var hasVTConfig = false
                while let config = avcodec_get_hw_config(nativeAV1, i) {
                    if config.pointee.device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX {
                        hasVTConfig = true
                        break
                    }
                    i += 1
                }

                if hasVTConfig {
                    // Try to create the VideoToolbox device context to verify physical/OS support
                    var hwDeviceCtx: UnsafeMutablePointer<AVBufferRef>? = nil
                    if av_hwdevice_ctx_create(&hwDeviceCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 {
                        // Success! We can use native AV1 with VideoToolbox hardware acceleration
                        av_buffer_unref(&hwDeviceCtx)
                        resolvedDecoder = nativeAV1
                        useVTForAV1 = true
                        print("🎬 rebuildVideoCodecContext: Selected native AV1 decoder with VideoToolbox hardware acceleration.")
                    } else {
                        print("ℹ️ rebuildVideoCodecContext: Native AV1 decoder has VideoToolbox config but hardware creation failed (likely M1/M2 or OS limitation). Falling back to software libdav1d.")
                    }
                } else {
                    print("ℹ️ rebuildVideoCodecContext: Native AV1 decoder does not support VideoToolbox in this FFmpeg build. Falling back to software libdav1d.")
                }
            }

            if !useVTForAV1 {
                // Fallback to high-performance software libdav1d
                if let dav1d = avcodec_find_decoder_by_name("libdav1d") {
                    resolvedDecoder = dav1d
                    print("🎬 rebuildVideoCodecContext: Selected software libdav1d decoder for AV1.")
                }
            }
        }

        guard let decoder = resolvedDecoder else {
            print("❌ rebuildVideoCodecContext: decoder not found")
            return
        }

        avcodec_free_context(&videoCodecContext)

        let newCtx = avcodec_alloc_context3(decoder)
        self.videoCodecContext = newCtx
        av_opt_set(newCtx, "threads", FFmpegPlaybackTuning.codecThreads, 0)
        avcodec_parameters_to_context(newCtx, codecpar)

        // 同样在此处绑定回调
        newCtx!.pointee.get_format = getFormatCallback

        var i: Int32 = 0
        var foundConfig = false
        while let config = avcodec_get_hw_config(decoder, i) {
            if config.pointee.device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX {
                var hwDeviceCtx: UnsafeMutablePointer<AVBufferRef>? = nil
                if av_hwdevice_ctx_create(&hwDeviceCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 {
                    newCtx!.pointee.hw_device_ctx = av_buffer_ref(hwDeviceCtx)
                    av_buffer_unref(&hwDeviceCtx)
                    print("✅ rebuildVideoCodecContext: VideoToolbox hwaccel enabled via config index \(i)")
                    foundConfig = true
                }
                break
            }
            i += 1
        }

        if !foundConfig {
            print("⚠️ rebuildVideoCodecContext: VideoToolbox hw_config not found for this decoder.")
        }

        var opts: OpaquePointer? = nil
        av_dict_set(&opts, "tilethreads", FFmpegPlaybackTuning.tileThreads, 0)
        av_dict_set(&opts, "framethreads", FFmpegPlaybackTuning.frameThreads, 0)
        av_dict_set(&opts, "threads", FFmpegPlaybackTuning.codecThreads, 0)

        if avcodec_open2(newCtx, decoder, &opts) < 0 {
            print("❌ rebuildVideoCodecContext: avcodec_open2 failed")
            av_dict_free(&opts)
        } else {
            print("✅ rebuildVideoCodecContext: VT pipeline rebuilt")
            av_dict_free(&opts)
        }
    }

    func closeFFmpeg() {
        if let swr = swrContext {
            var temp: OpaquePointer? = swr
            swr_free(&temp)
            swrContext = nil
        }
        if let vCtx = videoCodecContext {
            var temp: UnsafeMutablePointer<AVCodecContext>? = vCtx
            avcodec_free_context(&temp)
            videoCodecContext = nil
        }
        if let aCtx = audioCodecContext {
            var temp: UnsafeMutablePointer<AVCodecContext>? = aCtx
            avcodec_free_context(&temp)
            audioCodecContext = nil
        }
        if let ctx = formatContext {
            var temp: UnsafeMutablePointer<AVFormatContext>? = ctx
            avformat_close_input(&temp)
            formatContext = nil
        }

        videoStreamIndex = -1
        audioStreamIndex = -1
        videoDuration = 0.0
        videoFPS = 30.0
        videoFrameSize = .zero
        maxVideoQueueCapacity = FFmpegPlaybackTuning.normalQueueCapacity

        // Release pixel buffer pool
        softwareConversionLock.lock()
        if let sws = softwareSwsContext {
            sws_freeContext(sws)
            softwareSwsContext = nil
        }
        pixelBufferPool = nil
        poolWidth = 0
        poolHeight = 0
        softwareConversionLock.unlock()
    }

    func stopDecodeLoop() {
        decodeTask?.cancel()
        decodeTask = nil
        isPlaying = false

        // Clear callbacks to break retain cycles
        onFrameReady = nil
        onAudioReady = nil
        onStateChanged = nil
    }

    func startDecodeLoop() {
        decodeTask?.cancel()
        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            await self.runInternalDecodeLoop()
        }
    }

    private func runInternalDecodeLoop() async {
        let frame = av_frame_alloc()
        let packet = av_packet_alloc()

        guard let frame = frame, let packet = packet else { return }

        defer {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
            var p: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&p)
        }

        var loopCounter = 0
        while !Task.isCancelled {
            loopCounter += 1
            if loopCounter % 10 == 0 {
                await Task.yield() // Allow frame acknowledgements and seek commands onto the actor.
            }

            if !isPlaying || isSeekingSessionActive {
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                continue
            }

            if videoFrameQueueCount >= maxVideoQueueCapacity {
                try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms
                continue
            }

            let isEOF = decodeNextPacketSync(frame: frame, packet: packet, skipVideo: false)
            if isEOF {
                try? await Task.sleep(nanoseconds: 30_000_000) // 30ms sleep on EOF to avoid hot loop
            }
        }
    }

    @discardableResult
    private func decodeNextPacketSync(frame: UnsafeMutablePointer<AVFrame>, packet: UnsafeMutablePointer<AVPacket>, skipVideo: Bool = false) -> Bool {
        guard let ctx = formatContext, let vCtx = videoCodecContext else { return true }

        if !skipVideo {
            while avcodec_receive_frame(vCtx, frame) >= 0 {
                if self.videoFrameQueueCount >= maxVideoQueueCapacity {
                    av_frame_unref(frame)
                    return false
                }
                processVideoFrame(frame, ctx: ctx)
                av_frame_unref(frame)
            }
        } else {
            while avcodec_receive_frame(vCtx, frame) >= 0 {
                av_frame_unref(frame)
            }
        }

        av_packet_unref(packet)
        let readStatus = av_read_frame(ctx, packet)
        if readStatus >= 0 {
            if packet.pointee.stream_index == videoStreamIndex {
                let sendStatus = avcodec_send_packet(vCtx, packet)
                if sendStatus >= 0 && !skipVideo {
                    while avcodec_receive_frame(vCtx, frame) >= 0 {
                        if self.videoFrameQueueCount >= maxVideoQueueCapacity {
                            av_frame_unref(frame)
                            return false
                        }
                        processVideoFrame(frame, ctx: ctx)
                        av_frame_unref(frame)
                    }
                } else if sendStatus >= 0 && skipVideo {
                    while avcodec_receive_frame(vCtx, frame) >= 0 {
                        av_frame_unref(frame)
                    }
                }
            } else if packet.pointee.stream_index == audioStreamIndex, let aCtx = audioCodecContext, let swr = swrContext {
                let sendStatus = avcodec_send_packet(aCtx, packet)
                if sendStatus >= 0 {
                    while avcodec_receive_frame(aCtx, frame) >= 0 {
                        resampleAndQueueAudio(frame, context: swr, ctx: ctx)
                        av_frame_unref(frame)
                    }
                }
            }
            return false // Success, not EOF
        } else {
            return true // EOF or error
        }
    }

    private func processVideoFrame(_ frame: UnsafeMutablePointer<AVFrame>, ctx: UnsafeMutablePointer<AVFormatContext>) {
        let isHardware = frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue

        if isHardware {
            let pb = autoreleasepool { () -> CVPixelBuffer? in
                return convertFrameToPixelBuffer(frame)
            }
            if let pb = pb {
                let timeBase = ctx.pointee.streams[Int(videoStreamIndex)]!.pointee.time_base
                let pts = Double(frame.pointee.best_effort_timestamp) * Double(timeBase.num) / Double(timeBase.den)

                self.videoFrameQueueCount += 1
                let gen = self.frameEmitGeneration
                let sendableBuffer = SendablePixelBuffer(buffer: pb, generation: gen)
                let callback = self.onFrameReady
                Task { @MainActor in
                    callback?(sendableBuffer, pts)
                }
            }
        } else {
            // Software decode path — clone the frame and perform heavy sws_scale concurrently on global pool
            guard let rawClonedFrame = av_frame_alloc() else { return }
            nonisolated(unsafe) let clonedFrame = rawClonedFrame
            if av_frame_ref(clonedFrame, frame) < 0 {
                var f: UnsafeMutablePointer<AVFrame>? = clonedFrame
                av_frame_free(&f)
                return
            }

            let timeBase = ctx.pointee.streams[Int(videoStreamIndex)]!.pointee.time_base
            let pts = Double(frame.pointee.best_effort_timestamp) * Double(timeBase.num) / Double(timeBase.den)

            // Increment count synchronously to maintain queue flow control immediately
            self.videoFrameQueueCount += 1
            let gen = self.frameEmitGeneration

            let callback = self.onFrameReady
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else {
                    var f: UnsafeMutablePointer<AVFrame>? = clonedFrame
                    av_frame_free(&f)
                    return
                }

                let pb = autoreleasepool { () -> CVPixelBuffer? in
                    return self.convertFrameToPixelBuffer(clonedFrame)
                }

                var f: UnsafeMutablePointer<AVFrame>? = clonedFrame
                av_frame_free(&f)

                if let pb = pb {
                    let sendableBuffer = SendablePixelBuffer(buffer: pb, generation: gen)
                    await MainActor.run {
                        callback?(sendableBuffer, pts)
                    }
                } else {
                    // Decrement queue count if conversion fails
                    await self.acknowledgeVideoFrames(1, generation: gen)
                }
            }
        }
    }
}
