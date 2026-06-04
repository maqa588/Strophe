import SwiftUI
import AVFoundation
import Combine
import MetalKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - FrameQueue
// Synchronous, thread-safe frame queue protected by a recursive lock for zero-latency MainActor rendering.
final class FrameQueue: @unchecked Sendable {
    private var frames: [VideoFrame] = []
    private let lock = NSRecursiveLock()
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func enqueue(_ frame: VideoFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard frames.count < capacity else { return false }
        frames.append(frame)
        return true
    }

    func dequeueReady(before pts: Double) -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = frames.firstIndex(where: { $0.pts <= pts }) else { return nil }
        return frames.remove(at: idx)
    }

    func dequeueBestFrame(before pts: Double) -> (frame: VideoFrame?, droppedCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        guard let lastReadyIdx = frames.lastIndex(where: { $0.pts <= pts }) else {
            return (nil, 0)
        }
        
        let chosenFrame = frames[lastReadyIdx]
        let droppedCount = lastReadyIdx
        
        if droppedCount > 0 {
            frames.removeSubrange(0..<droppedCount)
        }
        
        frames.remove(at: 0)
        return (chosenFrame, droppedCount)
    }

    func dropBefore(_ pts: Double) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let before = frames.count
        frames.removeAll { $0.pts < pts - 0.1 }
        return before - frames.count
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll()
    }

    func peekFirst() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frames.first
    }

    func peekLast() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frames.last
    }
}

// MARK: - FFmpegEngine
// High-performance, `@MainActor`-isolated engine conforming perfectly to `PlayerEngine`.
@MainActor final class FFmpegEngine: NSObject, PlayerEngine {
    #if os(iOS)
    private static let frameQueueCapacity = 10
    #else
    private static let frameQueueCapacity = 24
    #endif

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
    
    // State conservation for scrubbing
    private var isScrubbingActive = false
    private var wasPlayingBeforeScrub = false
    private var rateBeforeScrub: Double = 0.0
    
    private let frameQueue = FrameQueue(capacity: FFmpegEngine.frameQueueCapacity)
    private var lastSeekTime: CFTimeInterval = 0
    private var activeSeekTask: Task<Void, Never>? = nil
    nonisolated(unsafe) private var diagTimer: Timer? = nil

    // Seek generation — incremented on every seek/load to discard stale pre-seek frames
    private var currentFrameGeneration: Int = 0


    
    nonisolated(unsafe) private var displayLink: CADisplayLink? = nil
    
    override init() {
        let renderer = MetalVideoRenderer()
        self.metalRenderer = renderer
        self.playerView = renderer
        
        let coreInstance = FFmpegDecoderCore()
        self.core = coreInstance
        
        let ap = AudioPlayer()
        self.audioPlayer = ap
        
        super.init()
        
        // Register callbacks safely on FFmpegDecoderCore actor asynchronously
        Task {
            await coreInstance.registerCallbacks(
                onFrameReady: { [weak self] sendableBuffer, pts in
                    guard let self = self else { return }

                    // ── Stale-frame guard ──────────────────────────────────────────
                    // If the generation stamp doesn't match, this callback was queued
                    // BEFORE the most recent seek/load. We simply discard it.
                    // DO NOT call decrementFrameQueueCount() here because the seek
                    // that bumped the generation also explicitly zeroed vfqCount, 
                    // which already accounted for the removal of these in-flight frames!
                    guard sendableBuffer.generation == self.currentFrameGeneration else {
                        return
                    }

                    if self.cachedRate == 0 {
                        self.metalRenderer.update(with: sendableBuffer.buffer)
                        Task {
                            await coreInstance.decrementFrameQueueCount()
                        }
                    } else {
                        // Log PTS vs clock mismatch when enqueueing
                        // let clock = self.currentTime
                        // if pts > clock + 2.0 {
                        //     print("⚠️ Frame PTS \(String(format: "%.3f", pts)) is \(String(format: "%.1f", pts - clock))s AHEAD of clock \(String(format: "%.3f", clock)) — queue may stall")
                        // }
                        let frame = VideoFrame(pixelBuffer: sendableBuffer.buffer, pts: pts)
                        let accepted = self.frameQueue.enqueue(frame)
                        if !accepted {
                            // If the queue is unexpectedly full, we drop the frame.
                            // DO NOT decrement vfqCount! This allows vfqCount to naturally
                            // rise to maxCapacity and put the decode loop to sleep, breaking
                            // any runaway loop caused by previous desynchronization.
                            print("⚠️ Frame dropped because queue is full. Self-healing vfqCount.")
                        }
                    }
                },
                onAudioReady: { [weak ap] left, right, pts in
                    ap?.schedulePCMData(left, right, presentationTime: pts)
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
                    self.updateDisplayLinkPreferredFrameRate()
                }
            )
        }
        
    }
    
    deinit {
        diagTimer?.invalidate()
        diagTimer = nil
        displayLink?.invalidate()
        displayLink = nil
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
            if isPlaybackStartedPending {
                return cachedStartPlaybackTime
            }
            return apTime
        }
        return systemClockTime
    }
    
    private var systemClockTime: Double {
        guard cachedIsPlaying else { return cachedStartPlaybackTime }
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
                let resumeTime = currentTime
                cachedStartSystemTime = CACurrentMediaTime()
                cachedStartPlaybackTime = resumeTime
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
        frameQueue.removeAll()
        // Bump generation before load so any queued callbacks from a previous
        // session are immediately discarded by the stale-frame guard.
        currentFrameGeneration += 1
        await core.seekClearAndNewGeneration(generation: currentFrameGeneration)
        
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
        activeSeekTask?.cancel()
        await core.cancelActiveSeekSession()
        
        let task = Task {
            // Capture playing state BEFORE any async calls that might trigger
            // state callbacks that could overwrite our cached values
            let wasPlaying = cachedIsPlaying || wasPlayingBeforeScrub
            let targetRate = wasPlaying ? (rateBeforeScrub > 0 ? rateBeforeScrub : 1.0) : 0.0
            
            // Reset scrub state
            isScrubbingActive = false
            wasPlayingBeforeScrub = false
            rateBeforeScrub = 0.0
            
            let countBefore = frameQueue.count
            print("🔍 Seek triggered: frameQueue.count before clear = \(countBefore)")
            if let lastFrame = frameQueue.peekLast() {
                metalRenderer.update(with: lastFrame.pixelBuffer)
            }
            frameQueue.removeAll()
            currentFrameGeneration += 1
            await core.seekClearAndNewGeneration(generation: currentFrameGeneration)
            await core.setIsPlaying(false)
            
            if Task.isCancelled { return }
            
            // Get the ACTUAL pts of the first decoded frame
            let actualPTS = await core.seekSession(to: time, exact: true)
            
            if Task.isCancelled { return }
            
            // Set audio baseTime to EXACTLY the same value as video first-frame PTS
            // This is the single source of truth
            audioPlayer.seek(to: actualPTS)
            
            // Add a tiny delay to allow AVAudioPlayerNode's internal AudioQueue to fully stop
            // before we potentially call play() below. This prevents kAudioQueueErr_InvalidRunState (-4).
            try? await Task.sleep(nanoseconds: 50_000_000)
            
            // Reset the system clock baseline AFTER seek completes
            cachedStartSystemTime = CACurrentMediaTime()
            cachedStartPlaybackTime = actualPTS
            lastSeekTime = cachedStartSystemTime
            
            // Notify core of new reference points
            await core.setStartSystemTime(cachedStartSystemTime)
            await core.setStartPlaybackTime(actualPTS)
            
            // Resume decode loop and audio together using saved state
            await core.setIsPlaying(wasPlaying)
            
            if wasPlaying {
                cachedStartSystemTime = CACurrentMediaTime()
                self.rate = targetRate
            }
        }
        activeSeekTask = task
        _ = await task.result
    }
    
    func seekVideoFrameOnly(to time: Double) async {
        activeSeekTask?.cancel()
        
        // Capture playback state immediately before the sleep phase to ensure we capture
        // the true original state prior to the scrubbing session, and pause immediately.
        if !isScrubbingActive {
            isScrubbingActive = true
            wasPlayingBeforeScrub = cachedIsPlaying
            rateBeforeScrub = cachedRate
        }
        rate = 0.0
        await core.cancelActiveSeekSession()
        
        let task = Task {
            // Cooperative sleep to debounce high-frequency timeline scrub events
            do {
                try await Task.sleep(nanoseconds: 15_000_000) // 15ms sleep
            } catch {
                return // Task was cancelled during sleep phase, abort.
            }
            
            let countBefore = frameQueue.count
            print("🔍 SeekVideoFrameOnly triggered: frameQueue.count before clear = \(countBefore)")
            if let lastFrame = frameQueue.peekLast() {
                metalRenderer.update(with: lastFrame.pixelBuffer)
            }
            frameQueue.removeAll()
            currentFrameGeneration += 1
            await core.seekClearAndNewGeneration(generation: currentFrameGeneration)
            
            if Task.isCancelled { return }
            
            // Pause audio stream during scrub previewing
            audioPlayer.pause()
            
            // Asynchronously seek and decode a single preview frame without touching audio playback
            let actualTime = await core.seekSession(to: time, exact: false)
            
            if Task.isCancelled { return }
            
            // Instantly align master playback time so timeline ruler updates dynamically while dragging
            cachedStartPlaybackTime = actualTime
            cachedStartSystemTime = CACurrentMediaTime()
            lastSeekTime = cachedStartSystemTime
        }
        activeSeekTask = task
        _ = await task.result
    }
    
    func stop() {
        // Invalidate diagnostic timer to break retain cycle
        diagTimer?.invalidate()
        diagTimer = nil
        
        rate = 0.0
        stopDisplayLink()
        
        displayLink?.invalidate()
        displayLink = nil
        
        Task {
            await core.stopDecodeLoop()
            await core.clearFrameQueueCount()
            await core.closeFFmpeg()
        }
        
        audioPlayer.stop()
        frameQueue.removeAll()
    }
    
    // MARK: - Display Link
    
    private func startDisplayLink() {
        if displayLink == nil {
            #if os(macOS)
            let dl = metalRenderer.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            #else
            let dl = CADisplayLink(target: self, selector: #selector(displayLinkFired(_:)))
            #endif
            dl.add(to: .main, forMode: .common)
            displayLink = dl
        }
        updateDisplayLinkPreferredFrameRate()
        displayLink?.isPaused = false
    }
    
    private func stopDisplayLink() {
        displayLink?.isPaused = true
    }
    
    private func updateDisplayLinkPreferredFrameRate() {
        #if os(iOS)
        guard let dl = displayLink else { return }
        if #available(iOS 15.0, *) {
            let range = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 0)
            dl.preferredFrameRateRange = range
        } else {
            dl.preferredFramesPerSecond = 60
        }
        #endif
    }
    
    @objc private func displayLinkFired(_ sender: CADisplayLink) {
        renderTick()
    }
    private func renderTick() {
        guard rate > 0 else {
            stopDisplayLink()
            return
        }
        let currentClock = currentTime
        
        let result = frameQueue.dequeueBestFrame(before: currentClock + 0.005)
        var consumed = 0
        
        if let frame = result.frame {
            self.metalRenderer.update(with: frame.pixelBuffer)
            consumed += 1
        }
        
        consumed += result.droppedCount
        
        let fallbackDropped = frameQueue.dropBefore(currentClock)
        consumed += fallbackDropped
        
        if consumed > 0 {
            let coreInstance = core
            let consumedCount = consumed
            Task {
                await coreInstance.decrementFrameQueueCount(by: consumedCount)
            }
        }
    }
}
