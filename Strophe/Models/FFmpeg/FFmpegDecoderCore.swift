import Foundation
import CoreVideo
import QuartzCore
import Libavcodec
import Libavformat
import Libavutil
import Libswscale
import Libswresample

// MARK: - FFmpegDecoderCore
// High-performance background demuxer/decoder isolated to its own serial actor context.
actor FFmpegDecoderCore {
    static let AV_NOPTS_VALUE = Int64(bitPattern: 0x8000000000000000)
    var maxVideoQueueCapacity = FFmpegPlaybackTuning.normalQueueCapacity
    
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
    var onAudioReady: (@Sendable ([Float], [Float], Double?, Int) -> Void)? = nil
    var onStateChanged: (@MainActor @Sendable (Double, Double, Double, CGSize, Double, Bool, Int32) -> Void)? = nil
    
    var decodeTask: Task<Void, Never>? = nil
    var activeSeekId: Int = 0
    
    // MARK: - CVPixelBuffer Pool for software decode path
    let poolLock = NSLock()
    nonisolated(unsafe) var pixelBufferPool: CVPixelBufferPool? = nil
    nonisolated(unsafe) var poolWidth: Int = 0
    nonisolated(unsafe) var poolHeight: Int = 0
    
    // MARK: - Safe State Accessors
    
    func registerCallbacks(
        onFrameReady: @MainActor @Sendable @escaping (SendablePixelBuffer, Double) -> Void,
        onAudioReady: @Sendable @escaping ([Float], [Float], Double?, Int) -> Void,
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
    
    /// Acknowledges frames only when they belong to the currently active
    /// generation. Delayed MainActor callbacks from before a seek must never
    /// decrement the new seek's queue count.
    func acknowledgeVideoFrames(_ amount: Int, generation: Int) {
        guard generation == frameEmitGeneration, amount > 0 else { return }
        videoFrameQueueCount = max(0, videoFrameQueueCount - amount)
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

    /// Atomically blocks decoding, invalidates older seeks, clears decoder
    /// buffers, and installs the generation used by the next seek.
    func prepareForSeek(generation: Int) -> Int {
        activeSeekId += 1
        isSeekingSessionActive = true
        isPlaying = false
        playbackRate = 0
        videoFrameQueueCount = 0
        frameEmitGeneration = generation

        if let vCtx = videoCodecContext {
            avcodec_flush_buffers(vCtx)
        }
        if let aCtx = audioCodecContext {
            avcodec_flush_buffers(aCtx)
        }
        notifyStateChanged()
        return activeSeekId
    }
    
    /// Repairs a starved decode loop without disturbing decoder timestamps.
    /// This is intentionally a soft recovery: it reconciles backpressure state,
    /// restores the expected play flag and restarts the loop only if it exited.
    func recoverStarvedDecodeFlow(
        generation: Int,
        actualQueueCount: Int,
        expectedRate: Double
    ) -> (previousCount: Int, restarted: Bool, resumed: Bool)? {
        guard generation == frameEmitGeneration, !isSeekingSessionActive else { return nil }

        let previousCount = videoFrameQueueCount
        let wasPlaying = isPlaying
        videoFrameQueueCount = max(0, actualQueueCount)
        playbackRate = expectedRate
        isPlaying = expectedRate > 0

        var restarted = false
        if decodeTask == nil || decodeTask?.isCancelled == true {
            startDecodeLoop()
            restarted = true
        }

        let resumed = !wasPlaying && isPlaying
        if resumed {
            notifyStateChanged()
        }
        return (previousCount, restarted, resumed)
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
    func seekSession(to time: Double, exact: Bool, seekId: Int) async -> Double? {
        guard seekId == activeSeekId else { return nil }

        isSeekingSessionActive = true
        defer {
            if seekId == activeSeekId {
                isSeekingSessionActive = false
                notifyStateChanged()
            }
        }
        
        // Yield to allow any other pending seeks to execute and update activeSeekId
        await Task.yield()
        if Task.isCancelled || seekId != activeSeekId {
            return nil
        }
        
        // prepareForSeek() installs the generation before this method runs, so
        // every emitted frame belongs to this seek unless a newer seek wins.
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
        
        if Task.isCancelled || seekId != activeSeekId {
            return nil
        }
        
        self.startPlaybackTime = time
        self.startSystemTime = CACurrentMediaTime()
        
        notifyStateChanged()
        
        let actualPTS = await seekAndQueueSingleFrame(to: time, seekId: seekId, exact: exact)

        guard seekId == activeSeekId, !Task.isCancelled else { return nil }
        startPlaybackTime = actualPTS
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
}
