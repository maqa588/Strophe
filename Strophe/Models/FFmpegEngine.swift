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
@MainActor final class FFmpegEngine: NSObject, PlayerEngine {
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
    
    private var videoFrameQueue: [VideoFrame] = []
    private var lastSeekTime: CFTimeInterval = 0
    private var diagTimer: Timer? = nil
    
    private var displayLink: CADisplayLink? = nil
    
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
                    
                    if self.cachedRate == 0 {
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
            // Use system clock during pending phase to avoid circular deadlocks
            if isPlaybackStartedPending {
                return systemClockTime
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
        let wasPlaying = cachedIsPlaying || wasPlayingBeforeScrub
        let targetRate = wasPlaying ? (rateBeforeScrub > 0 ? rateBeforeScrub : 1.0) : 0.0
        
        // Reset scrub state
        isScrubbingActive = false
        wasPlayingBeforeScrub = false
        rateBeforeScrub = 0.0
        
        print("🔍 Seek triggered: frameQueue.count before clear = \(videoFrameQueue.count)")
        if let lastFrame = videoFrameQueue.last {
            metalRenderer.update(with: lastFrame.pixelBuffer)
        }
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
    
    func seekVideoFrameOnly(to time: Double) async {
        // Capture playback state before starting scrub sequence
        if !isScrubbingActive {
            isScrubbingActive = true
            wasPlayingBeforeScrub = cachedIsPlaying
            rateBeforeScrub = cachedRate
        }
        
        // Pause playback rate and halt decode loop during scrubbing to prevent frame accumulation
        rate = 0.0
        
        print("🔍 SeekVideoFrameOnly triggered: frameQueue.count before clear = \(videoFrameQueue.count)")
        if let lastFrame = videoFrameQueue.last {
            metalRenderer.update(with: lastFrame.pixelBuffer)
        }
        videoFrameQueue.removeAll()
        await core.clearFrameQueueCount()
        
        // Pause audio stream during scrub previewing
        audioPlayer.pause()
        
        // Asynchronously seek and decode a single preview frame without touching audio playback
        let actualTime = await core.seekSession(to: time)
        
        // Instantly align master playback time so timeline ruler updates dynamically while dragging
        cachedStartPlaybackTime = actualTime
        cachedStartSystemTime = CACurrentMediaTime()
        lastSeekTime = cachedStartSystemTime
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
        videoFrameQueue.removeAll()
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
        
        var frameToRender: VideoFrame? = nil
        var consumed = 0
        
        while !videoFrameQueue.isEmpty {
            let nextFrame = videoFrameQueue.first!
            let delta = nextFrame.pts - currentClock
            
            let seekRecoveryWindow: CFTimeInterval = 1.0
            let isSeekRecovery = (CACurrentMediaTime() - lastSeekTime) < seekRecoveryWindow
            let dropThreshold = isSeekRecovery ? -0.5 : -0.1
            
            if delta < dropThreshold {
                // Video is more than 100ms behind audio, drop it to catch up
                videoFrameQueue.removeFirst()
                consumed += 1
            } else if delta > 0.015 {
                // Video is more than 15ms ahead of audio, wait for next tick
                break
            } else {
                // Video is in the sync window (-100ms <= delta <= 15ms), render it
                frameToRender = nextFrame
                videoFrameQueue.removeFirst()
                consumed += 1
                break
            }
        }
        
        if consumed > 0 {
            let amount = consumed
            Task {
                await core.decrementFrameQueueCount(by: amount)
            }
        }
        
        if let frame = frameToRender {
            metalRenderer.update(with: frame.pixelBuffer)
        }
    }
}

