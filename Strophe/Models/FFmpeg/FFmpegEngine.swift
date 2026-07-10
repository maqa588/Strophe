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
    private var seekGeneration: UInt = 0
    private var transportCommandGeneration: UInt = 0
    private var lastFrameArrivalTime = CACurrentMediaTime()
    private var lastStarvationRecoveryTime: CFTimeInterval = 0
    private var isStarvationRecoveryPending = false
    private var renderStatsStartTime = CACurrentMediaTime()
    private var renderedFrameCount = 0
    private var timingDroppedFrameCount = 0
    private var displayTickCount = 0
    private var emptyDisplayTickCount = 0
    private var accumulatedPresentationLead = 0.0
    nonisolated(unsafe) private var diagTimer: Timer? = nil

    // Seek generation — incremented on every seek/load to discard stale pre-seek frames
    private var currentFrameGeneration: Int = 0


    #if os(macOS)
    nonisolated(unsafe) private var displayTimer: Timer? = nil
    nonisolated(unsafe) private var displayLinkStorage: AnyObject? = nil
    #else
    nonisolated(unsafe) private var displayLink: CADisplayLink? = nil
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

                    if self.cachedRate == 0 {
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
            applyLocalTransportRate(targetRate)
            await core.setPlaybackRate(targetRate)
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
    
    // MARK: - Display Link
    
    private func startDisplayLink() {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            if displayLinkStorage == nil {
                let link = playerView.displayLink(
                    target: self,
                    selector: #selector(displayLinkFired(_:))
                )
                link.add(to: .main, forMode: .common)
                displayLinkStorage = link
            }
            updateDisplayLinkPreferredFrameRate()
            (displayLinkStorage as? CADisplayLink)?.isPaused = false
        } else if displayTimer == nil {
            let timer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(displayTimerFired(_:)),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            displayTimer = timer
        }
        #else
        if displayLink == nil {
            let dl = CADisplayLink(target: self, selector: #selector(displayLinkFired(_:)))
            dl.add(to: .main, forMode: .common)
            displayLink = dl
        }
        updateDisplayLinkPreferredFrameRate()
        displayLink?.isPaused = false
        #endif
    }
    
    private func stopDisplayLink() {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            (displayLinkStorage as? CADisplayLink)?.isPaused = true
        } else {
            displayTimer?.invalidate()
            displayTimer = nil
        }
        #else
        displayLink?.isPaused = true
        #endif
    }

    private func invalidateDisplayLink() {
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
    
    private func updateDisplayLinkPreferredFrameRate() {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            (displayLinkStorage as? CADisplayLink)?.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60,
                maximum: 120,
                preferred: Float(min(120, max(60, cachedFPS.rounded())))
            )
        }
        #else
        guard let dl = displayLink else { return }
        if #available(iOS 15.0, *) {
            let range = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 0)
            dl.preferredFrameRateRange = range
        } else {
            dl.preferredFramesPerSecond = 60
        }
        #endif
    }
    
    #if os(macOS)
    @objc private func displayTimerFired(_ sender: Timer) {
        renderTick(presentationLead: fallbackPresentationLead)
    }
    #endif

    #if os(macOS)
    @available(macOS 14.0, *)
    #endif
    @objc private func displayLinkFired(_ sender: CADisplayLink) {
        let lead = max(0, min(0.05, sender.targetTimestamp - CACurrentMediaTime()))
        renderTick(presentationLead: lead)
    }

    private var fallbackPresentationLead: Double {
        let fps = cachedFPS.isFinite && cachedFPS > 0 ? cachedFPS : 60
        return min(0.025, 0.75 / fps)
    }

    private func renderTick(presentationLead: Double) {
        guard rate > 0 else {
            stopDisplayLink()
            return
        }
        displayTickCount += 1
        accumulatedPresentationLead += presentationLead
        let currentClock = currentTime + presentationLead * rate
        
        let sourceFPS = cachedFPS.isFinite && cachedFPS > 0 ? cachedFPS : 60
        let allowedVideoLag = max(0.025, 2.0 / sourceFPS)
        let result = frameQueue.dequeueBestFrame(
            before: currentClock,
            droppingFramesBefore: currentClock - allowedVideoLag
        )
        if let frame = result.frame {
            self.metalRenderer.update(with: frame.pixelBuffer)
            renderedFrameCount += 1
            timingDroppedFrameCount += max(0, result.consumedCount - 1)
            let coreInstance = core
            let consumedCount = result.consumedCount
            let generation = frame.generation
            Task {
                await coreInstance.acknowledgeVideoFrames(
                    consumedCount,
                    generation: generation
                )
            }
        } else {
            emptyDisplayTickCount += 1
            recoverStarvedDecodeFlowIfNeeded(currentClock: currentClock)
        }
        reportRenderStatsIfNeeded()
    }

    private func reportRenderStatsIfNeeded() {
        let now = CACurrentMediaTime()
        let elapsed = now - renderStatsStartTime
        guard elapsed >= 5 else { return }

        let renderedFPS = Double(renderedFrameCount) / elapsed
        let averageLeadMS = displayTickCount > 0
            ? accumulatedPresentationLead / Double(displayTickCount) * 1_000
            : 0
        print(
            "📊 FFmpeg render: actual=\(String(format: "%.1f", renderedFPS))fps "
            + "source=\(String(format: "%.2f", cachedFPS))fps "
            + "queue=\(frameQueue.count) timingDrops=\(timingDroppedFrameCount) "
            + "ticks=\(displayTickCount) emptyTicks=\(emptyDisplayTickCount) "
            + "lead=\(String(format: "%.2f", averageLeadMS))ms"
        )
        renderStatsStartTime = now
        renderedFrameCount = 0
        timingDroppedFrameCount = 0
        displayTickCount = 0
        emptyDisplayTickCount = 0
        accumulatedPresentationLead = 0
    }

    private func recoverStarvedDecodeFlowIfNeeded(currentClock: Double) {
        let now = CACurrentMediaTime()
        guard rate > 0,
              frameQueue.count == 0,
              currentClock < max(0, duration - 0.25),
              now - lastFrameArrivalTime > 0.75,
              now - lastSeekTime > 0.75,
              now - lastStarvationRecoveryTime > 0.75,
              !isStarvationRecoveryPending else { return }

        isStarvationRecoveryPending = true
        lastStarvationRecoveryTime = now
        let generation = currentFrameGeneration
        let expectedRate = rate
        let actualCount = frameQueue.count
        let coreInstance = core

        Task { [weak self] in
            let recovery = await coreInstance.recoverStarvedDecodeFlow(
                generation: generation,
                actualQueueCount: actualCount,
                expectedRate: expectedRate
            )
            guard let self else { return }
            self.isStarvationRecoveryPending = false
            guard generation == self.currentFrameGeneration, let recovery else { return }

            if recovery.previousCount != actualCount || recovery.restarted || recovery.resumed {
                print(
                    "🩹 FFmpeg decode starvation recovered: coreQueue=\(recovery.previousCount) "
                    + "actualQueue=\(actualCount) restarted=\(recovery.restarted) "
                    + "resumed=\(recovery.resumed)"
                )
            }
        }
    }
}
