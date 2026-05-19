import SwiftUI
import AVFoundation
import Combine
import MetalKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - FFmpegEngine
// High-performance, `@MainActor`-isolated engine conforming perfectly to `PlayerEngine`.
@MainActor final class FFmpegEngine: PlayerEngine {
    let playerView: NativeView
    private let metalRenderer: MetalVideoRenderer
    private let audioPlayer: AudioPlayer
    private let core: FFmpegDecoderCore
    
    // Cached playback state updated via core.onStateChanged callback
    private var cachedDuration: Double = 0.0
    private var cachedFPS: Double = 30.0
    private var cachedVideoSize: CGSize = .zero
    private var cachedRate: Double = 0.0
    private var cachedIsPlaying: Bool = false
    private var cachedStartSystemTime: Double = 0.0
    private var cachedStartPlaybackTime: Double = 0.0
    private var cachedAudioStreamIndex: Int32 = -1
    private var isPlaybackStartedPending: Bool = false
    
    private var videoFrameQueue: [VideoFrame] = []
    private var diagTimer: Timer? = nil
    
    #if os(macOS)
    private var displayLink: CVDisplayLink? = nil
    #else
    private var displayLink: CADisplayLink? = nil
    #endif
    
    private let isTickPending = ThreadSafeAtomicBool()
    
    init() {
        let renderer = MetalVideoRenderer()
        self.metalRenderer = renderer
        self.playerView = renderer
        
        let coreInstance = FFmpegDecoderCore()
        self.core = coreInstance
        
        let ap = AudioPlayer()
        self.audioPlayer = ap
        
        // Register callbacks safely on FFmpegDecoderCore actor asynchronously
        Task {
            await coreInstance.registerCallbacks(
                onFrameReady: { [weak self] sendableBuffer, pts in
                    guard let self = self else { return }
                    
                    if self.cachedRate == 0 {
                        // If paused, render this frame immediately to avoid black screen and delay during seeking
                        self.metalRenderer.update(with: sendableBuffer.buffer)
                        self.videoFrameQueue.removeAll()
                        Task {
                            await coreInstance.clearFrameQueueCount()
                        }
                    } else {
                        let frame = VideoFrame(pixelBuffer: sendableBuffer.buffer, pts: pts)
                        self.videoFrameQueue.append(frame)
                        self.videoFrameQueue.sort { $0.pts < $1.pts }
                    }
                },
                onAudioReady: { [weak ap] left, right in
                    ap?.schedulePCMData(left, right)
                },
                onStateChanged: { [weak self] duration, fps, _, size, startPlaybackTime, _, audioIndex in
                    guard let self = self else { return }
                    self.cachedDuration = duration
                    self.cachedFPS = fps
                    // NOTE: cachedRate and cachedIsPlaying are NOT updated here.
                    // They are owned exclusively by the `rate` setter on MainActor.
                    // Updating them from the core's internal decode-loop state would
                    // create a feedback loop that kills playback after seek.
                    self.cachedVideoSize = size
                    self.cachedStartPlaybackTime = startPlaybackTime
                    self.cachedAudioStreamIndex = audioIndex
                }
            )
        }
        
        // Temporary diagnosis: print displayLink and renderer states every second
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            Task { @MainActor in
                #if os(macOS)
                if let dl = self.displayLink {
                    print("🔗 DisplayLink running: \(CVDisplayLinkIsRunning(dl)), rate: \(self.cachedRate)")
                } else {
                    print("🔗 DisplayLink: nil")
                }
                #endif
                print("🎯 MTKView isPaused: \(self.metalRenderer.isPaused), needsDisplay: \(self.metalRenderer.needsDisplay)")
                print("📦 videoFrameQueue count: \(self.videoFrameQueue.count)")
            }
        }
        self.diagTimer = timer
    }
    
    deinit {
        diagTimer?.invalidate()
        diagTimer = nil
        #if os(macOS)
        if let dl = displayLink {
            if CVDisplayLinkIsRunning(dl) {
                CVDisplayLinkStop(dl)
            }
        }
        displayLink = nil
        #endif
    }
    
    // MARK: - PlayerEngine Protocol
    
    var currentTime: Double {
        if cachedAudioStreamIndex >= 0 {
            let apTime = audioPlayer.currentTime
            if isPlaybackStartedPending && audioPlayer.isPlayingAndRendering {
                // The audio engine has finally started rendering to hardware!
                // Reset the master clock baseline to exactly now.
                cachedStartSystemTime = CACurrentMediaTime()
                cachedStartPlaybackTime = apTime
                isPlaybackStartedPending = false
                
                let captureSystemTime = cachedStartSystemTime
                let capturePlaybackTime = apTime
                let coreInstance = core
                Task {
                    await coreInstance.setStartSystemTime(captureSystemTime)
                    await coreInstance.setStartPlaybackTime(capturePlaybackTime)
                }
            }
            return apTime
        }
        return systemClockTime
    }
    
    private var systemClockTime: Double {
        guard cachedIsPlaying else { return cachedStartPlaybackTime }
        if isPlaybackStartedPending {
            return cachedStartPlaybackTime
        }
        let elapsed = CACurrentMediaTime() - cachedStartSystemTime
        return cachedStartPlaybackTime + elapsed * cachedRate
    }
    
    var duration: Double {
        return cachedDuration
    }
    
    var isRenderingAndPlaying: Bool {
        return cachedAudioStreamIndex < 0 || audioPlayer.isPlayingAndRendering
    }
    
    var fps: Double {
        get async {
            return cachedFPS
        }
    }
    
    var videoSize: CGSize {
        get async {
            return cachedVideoSize
        }
    }
    
    var rate: Double {
        get {
            return cachedRate
        }
        set {
            cachedRate = newValue
            cachedIsPlaying = newValue > 0
            
            Task {
                await core.setPlaybackRate(newValue)
            }
            
            if cachedIsPlaying {
                // ALWAYS snapshot system time at the moment of play resumption
                cachedStartSystemTime = CACurrentMediaTime()
                // Use actual current position as reference, not stale cached value
                cachedStartPlaybackTime = currentTime
                isPlaybackStartedPending = true // 🚀 Freeze systemClockTime and wait for hardware rendering start!
                
                let captureSystemTime = cachedStartSystemTime
                let capturePlaybackTime = cachedStartPlaybackTime
                let coreInstance = core
                Task {
                    await coreInstance.setStartSystemTime(captureSystemTime)
                    await coreInstance.setStartPlaybackTime(capturePlaybackTime)
                }
                
                audioPlayer.setRate(newValue)
                audioPlayer.play()
                startDisplayLink()
            } else {
                isPlaybackStartedPending = false // Clear pending
                // Snapshot position at pause moment
                cachedStartPlaybackTime = currentTime
                let capturePlaybackTime = cachedStartPlaybackTime
                let coreInstance = core
                Task {
                    await coreInstance.setStartPlaybackTime(capturePlaybackTime)
                }
                audioPlayer.pause()
                stopDisplayLink()
            }
        }
    }
    
    func load(url: URL) async {
        stopDisplayLink()
        videoFrameQueue.removeAll()
        await core.clearFrameQueueCount()
        
        await core.loadSession(url: url)
        
        if cachedAudioStreamIndex >= 0 {
            audioPlayer.seek(to: 0.0)
        }
        
        await core.startDecodeLoop()
        
        // Initialize clock baseline BEFORE setting rate
        cachedStartSystemTime = CACurrentMediaTime()
        cachedStartPlaybackTime = 0.0
        await core.setStartSystemTime(cachedStartSystemTime)
        await core.setStartPlaybackTime(0.0)
        
        rate = 0.0
    }
    
    func play() {
        rate = 1.0
    }
    
    func pause() {
        rate = 0.0
    }
    
    func seek(to time: Double) async {
        // Capture playing state BEFORE any async calls that might trigger
        // state callbacks that could overwrite our cached values
        let wasPlaying = cachedIsPlaying
        
        videoFrameQueue.removeAll()
        await core.clearFrameQueueCount()
        await core.setIsPlaying(false)
        
        // Get the ACTUAL pts of the first decoded frame
        let actualPTS = await core.seekSession(to: time)
        
        // Set audio baseTime to EXACTLY the same value as video first-frame PTS
        // This is the single source of truth
        audioPlayer.seek(to: actualPTS)
        
        // Reset the system clock baseline AFTER seek completes
        cachedStartSystemTime = CACurrentMediaTime()
        cachedStartPlaybackTime = actualPTS
        
        // Notify core of new reference points
        await core.setStartSystemTime(cachedStartSystemTime)
        await core.setStartPlaybackTime(actualPTS)
        
        // Resume decode loop and audio together using saved state
        await core.setIsPlaying(wasPlaying)
        
        if wasPlaying {
            isPlaybackStartedPending = true // 🚀 Set to pending until actual physical playback starts!
        } else {
            isPlaybackStartedPending = false
        }
        
        let hasAudio = cachedAudioStreamIndex >= 0
        if hasAudio {
            // Give Metal a brief 80ms cushion to receive and render the target video frame
            try? await Task.sleep(nanoseconds: 80_000_000)
            
            if wasPlaying {
                // Reset system master clock exactly when the audio starts physical playback
                cachedStartSystemTime = CACurrentMediaTime()
                audioPlayer.play()
            }
        } else {
            try? await Task.sleep(nanoseconds: 80_000_000)
            if wasPlaying {
                cachedStartSystemTime = CACurrentMediaTime()
            }
        }
    }
    
    func seekVideoFrameOnly(to time: Double) async {
        // Pause playback rate and halt decode loop during scrubbing to prevent frame accumulation
        rate = 0.0
        
        videoFrameQueue.removeAll()
        await core.clearFrameQueueCount()
        
        // Pause audio stream during scrub previewing
        audioPlayer.pause()
        
        // Asynchronously seek and decode a single preview frame without touching audio playback
        let actualTime = await core.seekSession(to: time)
        
        // Instantly align master playback time so timeline ruler updates dynamically while dragging
        cachedStartPlaybackTime = actualTime
        cachedStartSystemTime = CACurrentMediaTime()
    }
    
    func stop() {
        // Invalidate diagnostic timer to break retain cycle
        diagTimer?.invalidate()
        diagTimer = nil
        
        rate = 0.0
        stopDisplayLink()
        
        // Destroy display link completely
        #if os(macOS)
        if let dl = displayLink {
            if CVDisplayLinkIsRunning(dl) {
                CVDisplayLinkStop(dl)
            }
        }
        displayLink = nil
        #endif
        
        Task {
            await core.stopDecodeLoop()
            await core.clearFrameQueueCount()
            await core.closeFFmpeg()
        }
        
        audioPlayer.stop()
        videoFrameQueue.removeAll()
    }
    
    // MARK: - Display Link
    
    private func startDisplayLink() {
        #if os(macOS)
        if displayLink == nil {
            let status = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
            guard status == kCVReturnSuccess, let dl = displayLink else { return }
            
            let callback: CVDisplayLinkOutputCallback = { (_, _, _, _, _, refcon) -> CVReturn in
                guard let ref = refcon else { return kCVReturnSuccess }
                let engine = Unmanaged<FFmpegEngine>.fromOpaque(ref).takeUnretainedValue()
                
                // Backpressure throttle: only dispatch to MainActor if the previous renderTick finished!
                if engine.isTickPending.testAndSet(to: true) {
                    return kCVReturnSuccess
                }
                
                // Dispatch safely back to the MainActor
                DispatchQueue.main.async {
                    engine.renderTick()
                    engine.isTickPending.set(false)
                }
                return kCVReturnSuccess
            }
            
            CVDisplayLinkSetOutputCallback(dl, callback, Unmanaged.passUnretained(self).toOpaque())
        }
        
        if let dl = displayLink, !CVDisplayLinkIsRunning(dl) {
            CVDisplayLinkStart(dl)
        }
        #endif
    }
    
    private func stopDisplayLink() {
        #if os(macOS)
        if let dl = displayLink, CVDisplayLinkIsRunning(dl) {
            CVDisplayLinkStop(dl)
        }
        #endif
    }
    
    private func renderTick() {
        guard rate > 0 else {
            stopDisplayLink()
            return
        }
        let currentClock = currentTime
        
        var frameToRender: VideoFrame? = nil
        var droppedFramesCount = 0
        
        while !videoFrameQueue.isEmpty {
            let nextFrame = videoFrameQueue.first!
            
            if nextFrame.pts < currentClock - 0.01 {
                videoFrameQueue.removeFirst()
                droppedFramesCount += 1
            } else if nextFrame.pts > currentClock + 0.04 {
                break
            } else {
                frameToRender = nextFrame
                videoFrameQueue.removeFirst()
                droppedFramesCount += 1
                break
            }
        }
        
        // Notify the actor of all consumed frames synchronously
        if droppedFramesCount > 0 {
            Task {
                for _ in 0..<droppedFramesCount {
                    await core.decrementFrameQueueCount()
                }
            }
        }
        
        if let frame = frameToRender {
            metalRenderer.update(with: frame.pixelBuffer)
            
            if isPlaybackStartedPending {
                // First video frame successfully rendered for video-only files (or as fallback)!
                // Align the clock precisely to this frame's actual PTS.
                cachedStartSystemTime = CACurrentMediaTime()
                cachedStartPlaybackTime = frame.pts
                isPlaybackStartedPending = false
                
                let captureSystemTime = cachedStartSystemTime
                let capturePlaybackTime = frame.pts
                let coreInstance = core
                Task {
                    await coreInstance.setStartSystemTime(captureSystemTime)
                    await coreInstance.setStartPlaybackTime(capturePlaybackTime)
                }
            }
        }
    }
}

// MARK: - ThreadSafeAtomicBool
// Lightweight, thread-safe synchronization tool to prevent main queue flooding from high-frequency DisplayLink callbacks.
final class ThreadSafeAtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    
    func testAndSet(to newValue: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let oldValue = value
        value = newValue
        return oldValue
    }
    
    func set(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}
