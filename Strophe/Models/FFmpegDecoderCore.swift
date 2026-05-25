import Foundation
import CoreVideo
import QuartzCore
import Libavcodec
import Libavformat
import Libavutil
import Libswscale
import Libswresample

// MARK: - VideoFrame
struct VideoFrame: Sendable {
    let pixelBuffer: CVPixelBuffer
    let pts: Double
}

// MARK: - SendablePixelBuffer
struct SendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
    /// Seek generation stamp — used by FFmpegEngine to discard stale pre-seek callbacks.
    let generation: Int
}

// 用于向 FFmpeg 声明优先选择 VideoToolbox 硬件像素格式
nonisolated(unsafe) private let getFormatCallback: @convention(c) (UnsafeMutablePointer<AVCodecContext>?, UnsafePointer<AVPixelFormat>?) -> AVPixelFormat = { ctx, fmts in
    guard let fmts = fmts else { return AV_PIX_FMT_NONE }
    var i = 0
    while fmts[i] != AV_PIX_FMT_NONE {
        if fmts[i] == AV_PIX_FMT_VIDEOTOOLBOX {
            return AV_PIX_FMT_VIDEOTOOLBOX
        }
        i += 1
    }
    // 如果硬件不可用，降级使用列表中的第一个软件像素格式
    return fmts[0]
}

// MARK: - FFmpegDecoderCore
// High-performance background demuxer/decoder isolated to its own serial actor context.
actor FFmpegDecoderCore {
    static let AV_NOPTS_VALUE = Int64(bitPattern: 0x8000000000000000)
    let maxVideoQueueCapacity = 24
    
    // Core FFmpeg variables
    var formatContext: UnsafeMutablePointer<AVFormatContext>? = nil
    var videoCodecContext: UnsafeMutablePointer<AVCodecContext>? = nil
    var audioCodecContext: UnsafeMutablePointer<AVCodecContext>? = nil
    var swrContext: OpaquePointer? = nil
    var swsContext: UnsafeMutablePointer<SwsContext>? = nil
    
    var videoStreamIndex: Int32 = -1
    var audioStreamIndex: Int32 = -1
    
    var videoFPS: Double = 30.0
    var videoFrameSize: CGSize = .zero
    var videoDuration: Double = 0.0
    
    var playbackRate: Double = 0.0
    var isPlaying: Bool = false
    var isSeekingSessionActive: Bool = false
    
    var startSystemTime: Double = 0.0
    var startPlaybackTime: Double = 0.0
    
    var videoFrameQueueCount: Int = 0
    var frameEmitGeneration: Int = 0
    
    // Callbacks to push decoded frame, audio PCM, and state updates back to MainActor safely.
    var onFrameReady: (@MainActor @Sendable (SendablePixelBuffer, Double) -> Void)? = nil
    var onAudioReady: (@MainActor @Sendable ([Float], [Float]) -> Void)? = nil
    var onStateChanged: (@MainActor @Sendable (Double, Double, Double, CGSize, Double, Bool, Int32) -> Void)? = nil
    
    var decodeTask: Task<Void, Never>? = nil
    var seekTargetTime: Double? = nil
    var activeSeekId: Int = 0
    
    // MARK: - Safe State Accessors
    
    func registerCallbacks(
        onFrameReady: @MainActor @Sendable @escaping (SendablePixelBuffer, Double) -> Void,
        onAudioReady: @MainActor @Sendable @escaping ([Float], [Float]) -> Void,
        onStateChanged: @MainActor @Sendable @escaping (Double, Double, Double, CGSize, Double, Bool, Int32) -> Void
    ) {
        self.onFrameReady = onFrameReady
        self.onAudioReady = onAudioReady
        self.onStateChanged = onStateChanged
    }
    
    func getIsPlaying() -> Bool {
        return isPlaying
    }
    
    func getIsSeekingActive() -> Bool {
        return isSeekingSessionActive
    }
    
    func setIsPlaying(_ playing: Bool) {
        let changed = self.isPlaying != playing
        self.isPlaying = playing
        if changed {
            print("▶️ Playback state changed: playing=\(playing), vfqCount=\(videoFrameQueueCount)")
        }
        notifyStateChanged()
    }
    
    func setPlaybackRate(_ rate: Double) {
        let changed = self.playbackRate != rate
        self.playbackRate = rate
        self.isPlaying = rate > 0
        if changed {
            print("▶️ Playback rate changed: rate=\(rate), playing=\(self.isPlaying)")
        }
        notifyStateChanged()
    }
    
    func setStartSystemTime(_ time: Double) {
        self.startSystemTime = time
    }
    
    func setStartPlaybackTime(_ time: Double) {
        self.startPlaybackTime = time
    }
    
    func decrementFrameQueueCount() {
        self.videoFrameQueueCount = max(0, self.videoFrameQueueCount - 1)
    }
    
    func decrementFrameQueueCount(by amount: Int) {
        self.videoFrameQueueCount = max(0, self.videoFrameQueueCount - amount)
    }
    
    func clearFrameQueueCount() {
        self.videoFrameQueueCount = 0
    }

    /// Atomically clears the video frame queue count AND increments the seek
    /// generation.  Call this instead of clearFrameQueueCount() whenever a seek
    /// or load happens so that in-flight MainActor callbacks carrying the old
    /// generation are silently discarded by FFmpegEngine's stale-frame guard.
    func seekClearAndNewGeneration(generation: Int) {
        self.videoFrameQueueCount = 0
        self.frameEmitGeneration = generation
    }
    
    func getVideoFrameQueueCount() -> Int {
        return self.videoFrameQueueCount
    }
    
    // Performs load session entirely off the MainActor
    func loadSession(url: URL) async {
        closeFFmpeg()
        print("🔄 loadSession start: \(url.lastPathComponent)")
        let success = openInput(url: url)
        print("🔄 openInput result: \(success), videoStream: \(videoStreamIndex), audioStream: \(audioStreamIndex), duration: \(videoDuration), size: \(videoFrameSize)")
        if success {
            self.activeSeekId += 1
            let seekId = self.activeSeekId
            self.isSeekingSessionActive = true
            await seekAndQueueSingleFrame(to: 0.0, seekId: seekId, exact: false)
            if seekId == self.activeSeekId {
                self.isSeekingSessionActive = false
            }
            print("🔄 seekAndQueueSingleFrame done")
        }
        notifyStateChanged()
        print("🔄 loadSession complete")
    }
    
    // Performs seek session entirely off the MainActor
    func seekSession(to time: Double, exact: Bool) async -> Double {
        activeSeekId += 1
        let seekId = activeSeekId
        
        self.isSeekingSessionActive = true
        
        // Yield to allow any other pending seeks to execute and update activeSeekId
        await Task.yield()
        if seekId != activeSeekId {
            return time
        }
        
        self.seekTargetTime = time
        // NOTE: generation is bumped by the caller (FFmpegEngine) via
        // seekClearAndNewGeneration() BEFORE seekSession is called, so frames
        // produced here already carry the new generation.
        self.videoFrameQueueCount = 0
        
        if let ctx = self.formatContext {
            let timeBase = ctx.pointee.streams[Int(self.videoStreamIndex)]!.pointee.time_base
            let targetFrame = Int64(time * Double(timeBase.den) / Double(timeBase.num))
            
            av_seek_frame(ctx, self.videoStreamIndex, targetFrame, AVSEEK_FLAG_BACKWARD)
            
            if let vCtx = self.videoCodecContext {
                avcodec_flush_buffers(vCtx)
            }
            if let aCtx = self.audioCodecContext {
                avcodec_flush_buffers(aCtx)
            }
        }
        
        if seekId != activeSeekId {
            return time
        }
        
        self.startPlaybackTime = time
        self.startSystemTime = CACurrentMediaTime()
        
        notifyStateChanged()
        
        let actualPTS = await self.seekAndQueueSingleFrame(to: time, seekId: seekId, exact: exact)
        
        if seekId == activeSeekId {
            self.startPlaybackTime = actualPTS
            self.isSeekingSessionActive = false
            notifyStateChanged()
        }
        
        return actualPTS
    }
    
    func notifyStateChanged() {
        let duration = self.videoDuration
        let fps = self.videoFPS
        let rate = self.playbackRate
        let size = self.videoFrameSize
        let startPlaybackTime = self.startPlaybackTime
        let isPlaying = self.isPlaying
        let audioIndex = self.audioStreamIndex
        
        let callback = self.onStateChanged
        Task { @MainActor in
            callback?(duration, fps, rate, size, startPlaybackTime, isPlaying, audioIndex)
        }
    }
    
    // MARK: - Low-Level FFmpeg Logic
    
    func openInput(url: URL) -> Bool {
        let path = url.path
        var ctx: UnsafeMutablePointer<AVFormatContext>? = nil
        
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
        av_opt_set_int(vCtx, "threads", 0, 0)
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
        av_dict_set(&opts, "tilethreads", "0", 0)
        av_dict_set(&opts, "framethreads", "0", 0)
        av_dict_set(&opts, "threads", "0", 0)
        
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
        av_opt_set_int(newCtx, "threads", 0, 0)
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
        av_dict_set(&opts, "tilethreads", "0", 0)
        av_dict_set(&opts, "framethreads", "0", 0)
        av_dict_set(&opts, "threads", "0", 0)
        
        if avcodec_open2(newCtx, decoder, &opts) < 0 {
            print("❌ rebuildVideoCodecContext: avcodec_open2 failed")
            av_dict_free(&opts)
        } else {
            print("✅ rebuildVideoCodecContext: VT pipeline rebuilt")
            av_dict_free(&opts)
        }
    }
    
    func closeFFmpeg() {
        if let sws = swsContext {
            sws_freeContext(sws)
            swsContext = nil
        }
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
        
        // Release pixel buffer pool
        poolLock.lock()
        pixelBufferPool = nil
        poolWidth = 0
        poolHeight = 0
        poolLock.unlock()
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

        while !Task.isCancelled {
            await Task.yield() // ⚡️ Yield the actor executor to allow pending calls (e.g. decrementFrameQueueCount) to execute

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
                        resampleAndQueueAudio(frame, context: swr)
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
            guard let clonedFrame = av_frame_alloc() else { return }
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
                    await self.decrementFrameQueueCount()
                }
            }
        }
    }
    @discardableResult
    func seekAndQueueSingleFrame(to seconds: Double, seekId: Int, exact: Bool) async -> Double {
        guard let ctx = formatContext, let vCtx = videoCodecContext,
              let frame = av_frame_alloc(), let packet = av_packet_alloc(),
              let fallbackFrame = av_frame_alloc() else { return seconds }
        defer {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
            var p: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&p)
            var fb: UnsafeMutablePointer<AVFrame>? = fallbackFrame
            av_frame_free(&fb)
        }
        
        let timeBase = ctx.pointee.streams[Int(videoStreamIndex)]!.pointee.time_base
        var fallbackPTS: Double = seconds
        var hasFallback = false
        var count = 0
        let maxPackets = exact ? 500 : 30
        
        while count < maxPackets {
            if seekId != self.activeSeekId {
                print("⏭️ Aborting obsolete seek (target: \(seconds), new target ID: \(self.activeSeekId))")
                break
            }
            
            await Task.yield()
            if seekId != self.activeSeekId { break }
            
            av_packet_unref(packet)
            if av_read_frame(ctx, packet) < 0 { break }
            
            guard packet.pointee.stream_index == videoStreamIndex else {
                continue
            }
            
            var sendStatus = avcodec_send_packet(vCtx, packet)
            let gen = self.frameEmitGeneration  // capture once per packet iteration
            if sendStatus == -EAGAIN {
                // Decoder buffer is full, drain it first
                var found = false
                while avcodec_receive_frame(vCtx, frame) >= 0 {
                    let pts = Double(frame.pointee.best_effort_timestamp) * Double(timeBase.num) / Double(timeBase.den)
                    if !exact || pts >= seconds - 0.005 {
                        if seekId == self.activeSeekId {
                            if let pb = convertFrameToPixelBuffer(frame) {
                                self.startPlaybackTime = pts
                                let sendableBuffer = SendablePixelBuffer(buffer: pb, generation: gen)
                                self.videoFrameQueueCount += 1
                                let callback = self.onFrameReady
                                let capturePTS = pts
                                Task { @MainActor in
                                    callback?(sendableBuffer, capturePTS)
                                }
                            }
                        }
                        fallbackPTS = pts
                        found = true
                        av_frame_unref(frame)
                        break
                    }
                    
                    av_frame_unref(fallbackFrame)
                    av_frame_ref(fallbackFrame, frame)
                    fallbackPTS = pts
                    hasFallback = true
                    av_frame_unref(frame)
                }
                if found {
                    return fallbackPTS
                }
                // Try sending again
                sendStatus = avcodec_send_packet(vCtx, packet)
            }
            
            if sendStatus >= 0 {
                var found = false
                while avcodec_receive_frame(vCtx, frame) >= 0 {
                    let pts = Double(frame.pointee.best_effort_timestamp) * Double(timeBase.num) / Double(timeBase.den)
                    if !exact || pts >= seconds - 0.005 {
                        if seekId == self.activeSeekId {
                            if let pb = convertFrameToPixelBuffer(frame) {
                                self.startPlaybackTime = pts
                                let sendableBuffer = SendablePixelBuffer(buffer: pb, generation: gen)
                                self.videoFrameQueueCount += 1
                                let callback = self.onFrameReady
                                let capturePTS = pts
                                Task { @MainActor in
                                    callback?(sendableBuffer, capturePTS)
                                }
                            }
                        }
                        fallbackPTS = pts
                        found = true
                        av_frame_unref(frame)
                        break
                    }
                    
                    av_frame_unref(fallbackFrame)
                    av_frame_ref(fallbackFrame, frame)
                    fallbackPTS = pts
                    hasFallback = true
                    av_frame_unref(frame)
                }
                if found {
                    return fallbackPTS
                }
            }
            
            count += 1
        }
        
        // Fallback: If exact frame not reached or EOF, render the last decoded frame
        if hasFallback && seekId == self.activeSeekId {
            let gen = self.frameEmitGeneration
            if let pb = convertFrameToPixelBuffer(fallbackFrame) {
                self.startPlaybackTime = fallbackPTS
                let sendableBuffer = SendablePixelBuffer(buffer: pb, generation: gen)
                self.videoFrameQueueCount += 1
                let callback = self.onFrameReady
                let capturePTS = fallbackPTS
                Task { @MainActor in
                    callback?(sendableBuffer, capturePTS)
                }
            }
            return fallbackPTS
        }
        
        return seconds
    }
    
    func resampleAndQueueAudio(_ frame: UnsafeMutablePointer<AVFrame>, context: OpaquePointer) {
        let swr = context
        let sampleCount = frame.pointee.nb_samples
        
        let maxOutSamples = swr_get_delay(swr, 44100) + Int64(sampleCount)
        let capacity = Int(maxOutSamples)
        
        let leftBuffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        let rightBuffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        
        defer {
            leftBuffer.deallocate()
            rightBuffer.deallocate()
        }
        
        var outData: [UnsafeMutablePointer<UInt8>?] = [
            UnsafeMutablePointer<UInt8>(OpaquePointer(leftBuffer)),
            UnsafeMutablePointer<UInt8>(OpaquePointer(rightBuffer)),
            nil, nil, nil, nil, nil, nil
        ]
        
        let srcData = withUnsafePointer(to: &frame.pointee.data) { ptr in
            ptr.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { $0 }
        }
        
        let outSamples = swr_convert(
            swr,
            &outData,
            Int32(capacity),
            srcData,
            Int32(sampleCount)
        )
        
        if outSamples > 0 {
            let left = Array(UnsafeBufferPointer(start: leftBuffer, count: Int(outSamples)))
            let right = Array(UnsafeBufferPointer(start: rightBuffer, count: Int(outSamples)))
            let callback = self.onAudioReady
            Task { @MainActor in
                callback?(left, right)
            }
        }
    }
    // MARK: - CVPixelBuffer Pool for software decode path
    private let poolLock = NSLock()
    nonisolated(unsafe) var pixelBufferPool: CVPixelBufferPool? = nil
    nonisolated(unsafe) var poolWidth: Int = 0
    nonisolated(unsafe) var poolHeight: Int = 0
    
    nonisolated func convertFrameToPixelBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width  = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)

        if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            if let pb = frame.pointee.data.3 {
                return Unmanaged<CVPixelBuffer>.fromOpaque(pb).takeUnretainedValue()
            }
        }

        // Software decode path — use a CVPixelBufferPool to reuse buffers
        // instead of creating new ones every frame (prevents FPS degradation)
        poolLock.lock()
        if pixelBufferPool == nil || poolWidth != width || poolHeight != height {
            // (Re)create pool for current resolution
            pixelBufferPool = nil
            poolWidth = width
            poolHeight = height
            
            let poolAttrs: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: 3
            ]
            let bufferAttrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey: true
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                   poolAttrs as CFDictionary,
                                   bufferAttrs as CFDictionary,
                                   &pixelBufferPool)
        }
        let pool = pixelBufferPool
        poolLock.unlock()
        
        var pixelBuffer: CVPixelBuffer?
        guard let pool = pool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let yPlane  = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let uvPlane = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }

        let yStride  = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)

        let srcFmt = AVPixelFormat(rawValue: frame.pointee.format)
        
        // Allocate a local SwsContext to make format conversion thread-safe and concurrent
        let localSwsCtx = sws_getContext(
            Int32(width), Int32(height), srcFmt,
            Int32(width), Int32(height), AV_PIX_FMT_NV12,
            Int32(SWS_FAST_BILINEAR.rawValue), nil, nil, nil
        )
        guard let swsCtx = localSwsCtx else { return nil }
        defer { sws_freeContext(swsCtx) }

        var dstData: [UnsafeMutablePointer<UInt8>?] = [
            yPlane.assumingMemoryBound(to: UInt8.self),
            uvPlane.assumingMemoryBound(to: UInt8.self),
            nil, nil
        ]
        var dstLinesize: [Int32] = [Int32(yStride), Int32(uvStride), 0, 0]

        _ = frame.withMemoryRebound(to: AVFrame.self, capacity: 1) { framePtr in
            let srcData = withUnsafePointer(to: &framePtr.pointee.data) {
                $0.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { $0 }
            }
            let srcLinesize = withUnsafePointer(to: &framePtr.pointee.linesize) {
                $0.withMemoryRebound(to: Int32.self, capacity: 8) { $0 }
            }
            return sws_scale(swsCtx, srcData, srcLinesize, 0, Int32(height), &dstData, &dstLinesize)
        }

        return pb
    }
}
