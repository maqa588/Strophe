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
// Synchronous, thread-safe frame queue protected by a small critical section.
final class FrameQueue: @unchecked Sendable {
    private var frames: [VideoFrame] = []
    private let lock = NSLock()
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func enqueue(_ frame: VideoFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard frames.count < capacity else { return false }
        if let last = frames.last, frame.pts < last.pts {
            let insertionIndex = frames.firstIndex(where: { $0.pts > frame.pts }) ?? frames.endIndex
            frames.insert(frame, at: insertionIndex)
        } else {
            frames.append(frame)
        }
        return true
    }

    func dequeueBestFrame(
        before pts: Double,
        droppingFramesBefore stalePTS: Double
    ) -> (frame: VideoFrame?, consumedCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        guard let lastReadyIdx = frames.lastIndex(where: { $0.pts <= pts }) else {
            return (nil, 0)
        }

        // Prefer the oldest ready frame for stable cadence. Only catch up by
        // dropping when video has fallen more than the bounded A/V lag behind.
        let lastStaleIdx = frames.lastIndex(where: { $0.pts < stalePTS }) ?? 0
        let chosenIndex = min(lastReadyIdx, lastStaleIdx)
        let chosenFrame = frames[chosenIndex]
        let consumedCount = chosenIndex + 1
        frames.removeSubrange(0...chosenIndex)
        return (chosenFrame, consumedCount)
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

}

// MARK: - FFmpegEngine
// High-performance, `@MainActor`-isolated engine conforming perfectly to `PlayerEngine`.
@MainActor final class FFmpegEngine: NSObject, PlayerEngine {
    #if os(iOS)
    private static let frameQueueCapacity = 10
    #else
    private static let frameQueueCapacity = 32
    #endif

    let playerView: NativeView
    let metalRenderer: MetalVideoRenderer
    private let audioPlayer: AudioPlayer
    let core: FFmpegDecoderCore
    
    // Cached playback state updated via core.onStateChanged callback
    private var cachedDuration: Double = 0.0
    var cachedFPS: Double = 30.0
    private var cachedVideoSize: CGSize = .zero
    private var cachedRate: Double = 0.0
    private var cachedIsPlaying: Bool = false
    private var cachedStartSystemTime: Double = 0.0
    private var cachedStartPlaybackTime: Double = 0.0
    private var cachedAudioStreamIndex: Int32 = -1
    private var isPlaybackStartedPending: Bool = false
    private var isRemoteSource = false
    private var isRemoteSeekPrerolling = false
    
    // State conservation for scrubbing
    private var isScrubbingActive = false
    private var wasPlayingBeforeScrub = false
    private var rateBeforeScrub: Double = 0.0
    
    let frameQueue = FrameQueue(capacity: FFmpegEngine.frameQueueCapacity)
    var lastSeekTime: CFTimeInterval = 0
    private var seekGeneration: UInt = 0
    private var transportCommandGeneration: UInt = 0
    var lastFrameArrivalTime = CACurrentMediaTime()
    var lastStarvationRecoveryTime: CFTimeInterval = 0
    var isStarvationRecoveryPending = false
    var renderStatsStartTime = CACurrentMediaTime()
    var renderedFrameCount = 0
    var timingDroppedFrameCount = 0
    var displayTickCount = 0
    var emptyDisplayTickCount = 0
    var accumulatedPresentationLead = 0.0
    nonisolated(unsafe) private var diagTimer: Timer? = nil

    // Seek generation — incremented on every seek/load to discard stale pre-seek frames
    var currentFrameGeneration: Int = 0


    #if os(macOS)
    nonisolated(unsafe) var displayTimer: Timer? = nil
    nonisolated(unsafe) var displayLinkStorage: AnyObject? = nil
    #else
    nonisolated(unsafe) var displayLink: CADisplayLink? = nil
    #endif
    
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
        Task { [coreInstance, weak self, weak ap] in
            await coreInstance.registerCallbacks(
                onFrameReady: { [weak self] sendableBuffer, pts in
                    guard let self = self else { return }

                    // ── Stale-frame guard ──────────────────────────────────────────
                    // If the generation stamp doesn't match, this callback was queued
                    // BEFORE the most recent seek/load. We simply discard it.
                    guard sendableBuffer.generation == self.currentFrameGeneration else {
                        Task {
                            await coreInstance.acknowledgeVideoFrames(
                                1,
                                generation: sendableBuffer.generation
                            )
                        }
                        return
                    }

                    self.lastFrameArrivalTime = CACurrentMediaTime()

                    if self.cachedRate == 0 && !self.isRemoteSeekPrerolling {
                        self.metalRenderer.update(with: sendableBuffer.buffer)
                        Task {
                            await coreInstance.acknowledgeVideoFrames(
                                1,
                                generation: sendableBuffer.generation
                            )
                        }
                    } else {
                        // Log PTS vs clock mismatch when enqueueing
                        // let clock = self.currentTime
                        // if pts > clock + 2.0 {
                        //     print("⚠️ Frame PTS \(String(format: "%.3f", pts)) is \(String(format: "%.1f", pts - clock))s AHEAD of clock \(String(format: "%.3f", clock)) — queue may stall")
                        // }
                        let frame = VideoFrame(
                            pixelBuffer: sendableBuffer.buffer,
                            pts: pts,
                            generation: sendableBuffer.generation
                        )
                        let accepted = self.frameQueue.enqueue(frame)
                        if !accepted {
                            Task {
                                await coreInstance.acknowledgeVideoFrames(
                                    1,
                                    generation: sendableBuffer.generation
                                )
                            }
                        }
                    }
                },
                onAudioReady: { [weak ap] left, right, pts, _ in
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
        #if os(macOS)
        displayTimer?.invalidate()
        displayTimer = nil
        if #available(macOS 14.0, *) {
            (displayLinkStorage as? CADisplayLink)?.invalidate()
            displayLinkStorage = nil
        }
        #else
        displayLink?.invalidate()
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
            let safeRate = newValue.isFinite && newValue > 0 ? newValue : 0
            transportCommandGeneration &+= 1
            let generation = transportCommandGeneration
            applyLocalTransportRate(safeRate)

            let coreInstance = core
            Task { [weak self] in
                guard let self, self.transportCommandGeneration == generation else { return }
                await coreInstance.setPlaybackRate(safeRate)
            }
        }
    }

    private func applyLocalTransportRate(_ newRate: Double) {
        let previousRate = cachedRate
        let clockBeforeChange = currentTime
        cachedRate = newRate
        cachedIsPlaying = newRate > 0
        cachedStartSystemTime = CACurrentMediaTime()
        cachedStartPlaybackTime = clockBeforeChange

        if cachedIsPlaying {
            if previousRate <= 0 {
                lastFrameArrivalTime = cachedStartSystemTime
                renderStatsStartTime = cachedStartSystemTime
                renderedFrameCount = 0
                timingDroppedFrameCount = 0
                displayTickCount = 0
                emptyDisplayTickCount = 0
                accumulatedPresentationLead = 0
            }
            isPlaybackStartedPending = cachedAudioStreamIndex >= 0
            audioPlayer.setRate(newRate)
            audioPlayer.play()
            startDisplayLink()
        } else {
            isPlaybackStartedPending = false
            audioPlayer.pause()
            stopDisplayLink()
        }
    }

    private func pauseTransportForSeek() {
        transportCommandGeneration &+= 1
        applyLocalTransportRate(0)
    }
    
    @discardableResult
    func load(url: URL) async -> Bool {
        isRemoteSource = FormatDetector.isRemoteNetworkVolume(url)
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
        return !Task.isCancelled
    }
    
    func play() {
        rate = 1.0
    }
    
    func pause() {
        rate = 0.0
    }
    
    @discardableResult
    func seek(to time: Double) async -> Bool {
        await performSeek(to: time, exact: true)
    }

    @discardableResult
    func seekExactly(to time: Double) async -> Bool {
        await performSeek(to: time, exact: true)
    }

    private func performSeek(to time: Double, exact: Bool) async -> Bool {
        guard time.isFinite else { return false }

        let wasPlaying = cachedIsPlaying || wasPlayingBeforeScrub
        let targetRate = wasPlaying ? (rateBeforeScrub > 0 ? rateBeforeScrub : max(cachedRate, 1.0)) : 0.0

        isScrubbingActive = false
        wasPlayingBeforeScrub = false
        rateBeforeScrub = 0

        seekGeneration &+= 1
        let operation = seekGeneration
        pauseTransportForSeek()
        frameQueue.removeAll()
        currentFrameGeneration += 1
        lastSeekTime = CACurrentMediaTime()
        lastFrameArrivalTime = lastSeekTime

        let seekID = await core.prepareForSeek(generation: currentFrameGeneration)
        guard operation == seekGeneration, !Task.isCancelled else { return false }
        guard let actualPTS = await core.seekSession(to: time, exact: exact, seekId: seekID) else {
            return false
        }
        guard operation == seekGeneration, !Task.isCancelled else { return false }

        audioPlayer.seek(to: actualPTS)
        cachedStartSystemTime = CACurrentMediaTime()
        cachedStartPlaybackTime = actualPTS
        lastSeekTime = cachedStartSystemTime
        lastFrameArrivalTime = lastSeekTime
        await core.setStartSystemTime(cachedStartSystemTime)
        await core.setStartPlaybackTime(actualPTS)

        transportCommandGeneration &+= 1
        if wasPlaying {
            if isRemoteSource {
                // Let the decoder refill a small local queue before restarting
                // the audio/master clock. Otherwise SMB latency immediately
                // after a random seek is exposed as visible starvation.
                isRemoteSeekPrerolling = true
                await core.setPlaybackRate(targetRate)
                let deadline = CACurrentMediaTime() + 0.65
                let targetFrames = min(8, max(4, Int(cachedFPS / 4)))
                while operation == seekGeneration,
                      !Task.isCancelled,
                      frameQueue.count < targetFrames,
                      CACurrentMediaTime() < deadline {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                if operation == seekGeneration {
                    isRemoteSeekPrerolling = false
                }
                guard operation == seekGeneration, !Task.isCancelled else { return false }
                applyLocalTransportRate(targetRate)
            } else {
                applyLocalTransportRate(targetRate)
                await core.setPlaybackRate(targetRate)
            }
        } else {
            await core.setPlaybackRate(0)
        }
        return operation == seekGeneration
    }
    
    @discardableResult
    func seekVideoFrameOnly(to time: Double) async -> Bool {
        // Capture playback state immediately before the sleep phase to ensure we capture
        // the true original state prior to the scrubbing session, and pause immediately.
        if !isScrubbingActive {
            isScrubbingActive = true
            wasPlayingBeforeScrub = cachedIsPlaying
            rateBeforeScrub = cachedRate
        }

        seekGeneration &+= 1
        let operation = seekGeneration
        pauseTransportForSeek()
        frameQueue.removeAll()
        currentFrameGeneration += 1
        lastSeekTime = CACurrentMediaTime()
        lastFrameArrivalTime = lastSeekTime

        let seekID = await core.prepareForSeek(generation: currentFrameGeneration)
        guard operation == seekGeneration, !Task.isCancelled else { return false }
        guard let actualTime = await core.seekSession(to: time, exact: false, seekId: seekID) else {
            return false
        }
        guard operation == seekGeneration, !Task.isCancelled else { return false }

        cachedStartPlaybackTime = actualTime
        cachedStartSystemTime = CACurrentMediaTime()
        lastSeekTime = cachedStartSystemTime
        return true
    }
    
    func stop() {
        // Invalidate diagnostic timer to break retain cycle
        diagTimer?.invalidate()
        diagTimer = nil
        
        rate = 0.0
        stopDisplayLink()
        
        invalidateDisplayLink()
        
        Task {
            await core.stopDecodeLoop()
            await core.clearFrameQueueCount()
            await core.closeFFmpeg()
        }
        
        audioPlayer.stop()
        frameQueue.removeAll()
    }
    
    // Display link and rendering methods are in FFmpegEngine+DisplayLink.swift
}
