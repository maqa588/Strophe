//
//  VideoPlayerView+Setup.swift
//  Strophe
//
//  Created by Antigravity on 2026/07/12.
//

import SwiftUI
import AVFoundation
import CoreImage
import UniformTypeIdentifiers

extension VideoPlayerView {

    // MARK: - Player Setup

    func setupPlayer(url: URL?) {
        setupGeneration &+= 1
        let generation = setupGeneration
        setupTask?.cancel()

        guard let url = url else {
            project.resetPlayerEngine()
            tearDownCurrentPlayer()
            return
        }

        // Guard against duplicate/re-entrant setup for the same URL
        if currentURL == url {
            if engine != nil {
                setupTimeObserver()
                setupScrubTask()
            }
            return
        }

        // Guard if we are currently prompting compatibility check for this exact URL
        if pendingCompatibilityURL == url { return }

        // 🌟 Check if there is already an active engine for this video in the project context.
        // This occurs when SwiftUI transitions between horizontal size classes (compact/regular)
        // or layout orientations, which recreates the VideoPlayerView struct.
        if let existingEngine = project.activeEngine,
           project.activeEngineURL == url {
            self.engine = existingEngine
            self.currentURL = url
            setupTimeObserver()
            setupScrubTask()
            return
        }

        tearDownCurrentPlayer()
        project.videoSize = .zero  // reset so aspectRatio updates once new size is detected

        setupTask = Task { @MainActor in
            let result = await FormatDetector.shared.detect(url: url)
            guard !Task.isCancelled, setupGeneration == generation, project.videoURL == url else { return }

            if result.isAVFoundationCompatible {
                guard let avEngine = await project.acquirePlayerEngine(
                    for: url,
                    makeEngine: { AVFoundationEngine() }
                ) else { return }
                guard !Task.isCancelled, setupGeneration == generation, project.videoURL == url else { return }
                currentURL = url
                engine = avEngine
                _ = await avEngine.seek(to: project.currentTime.clampedFinite(to: 0...avEngine.duration))
                setupScrubTask()

                setupFrameRateDetection(url: url, engine: avEngine)

                // Window adjustment will happen automatically in setupFrameRateDetection after size is fetched
            } else {
                // Not native AVFoundation compatible (MKV, WebM, RMVB, AVI, FLV etc.) or SMB remote share
                if result.isRemoteNetworkVolume {
                    // Show remote network warning
                    self.isRemoteVolumeAlert = true
                    self.incompatibleFormatName = url.pathExtension.uppercased()
                    self.pendingCompatibilityURL = url
                    self.showingCompatibilityAlert = true
                } else {
                    // Local FFmpeg format - load directly!
                    guard let ffmpegEngine = await project.acquirePlayerEngine(
                        for: url,
                        makeEngine: { FFmpegEngine() }
                    ), project.videoURL == url else { return }

                    currentURL = url
                    engine = ffmpegEngine
                    _ = await ffmpegEngine.seek(
                        to: project.currentTime.clampedFinite(to: 0...ffmpegEngine.duration)
                    )
                    setupScrubTask()
                    setupFrameRateDetection(url: url, engine: ffmpegEngine)
                }
            }
        }
    }

    func tearDownCurrentPlayer() {
        if let token = timeObserverToken {
            timeObserverPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
            timeObserverPlayer = nil
        }
        timeObserverTask?.cancel()
        timeObserverTask = nil
        scrubTask?.cancel()
        scrubTask = nil
        scrubContinuation = nil
        pendingCompatibilityURL = nil
        showingCompatibilityAlert = false

        engine = nil
        currentURL = nil
        project.playbackRate = 0
    }

    func suspendPlayerObservers() {
        engine?.pause()
        project.playbackRate = 0
        if let currentTime = engine?.currentTime, currentTime.isFinite {
            project.currentTime = currentTime
            project.referenceTime = currentTime
            project.referenceDate = .now
        }

        if let token = timeObserverToken {
            timeObserverPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
            timeObserverPlayer = nil
        }
        timeObserverTask?.cancel()
        timeObserverTask = nil
        scrubTask?.cancel()
        scrubTask = nil
    }

    func setupTimeObserver() {
        if let token = timeObserverToken {
            timeObserverPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
            timeObserverPlayer = nil
        }
        timeObserverTask?.cancel()
        timeObserverTask = nil

        if let avEngine = engine as? AVFoundationEngine {
            let playerRef = avEngine.playerRef
            let fps = Int(min(60, max(24, project.videoFrameRate.rounded())))
            timeObserverPlayer = playerRef
            timeObserverToken = playerRef.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: CMTimeScale(fps)),
                queue: .main
            ) { [weak project, weak playerRef] time in
                guard let project, let playerRef else { return }
                let seconds = time.seconds
                let rate = Double(playerRef.rate)
                Task { @MainActor in
                    guard seconds.isFinite else { return }
                    guard !project.isSeeking && !project.isScrubbing else { return }
                    let subtitleText = project.subtitleText(at: seconds)
                    project.currentTime = seconds
                    project.referenceTime = seconds
                    project.referenceDate = .now
                    project.playbackRate = rate
                    if subtitleText != project.currentSubtitleText {
                        project.currentSubtitleText = subtitleText
                    }
                }
            }
        } else if let ffmpegEngine = engine as? FFmpegEngine {
            timeObserverTask = Task { @MainActor in
                while !Task.isCancelled {
                    let rate = ffmpegEngine.rate
                    if rate > 0 {
                        let seconds = ffmpegEngine.currentTime
                        guard seconds.isFinite else {
                            try? await Task.sleep(nanoseconds: 16_000_000)
                            continue
                        }
                        guard !project.isSeeking && !project.isScrubbing else {
                            try? await Task.sleep(nanoseconds: 16_000_000)
                            continue
                        }

                        let isRendering = ffmpegEngine.isRenderingAndPlaying
                        let subtitleText = project.subtitleText(at: seconds)

                        project.currentTime = seconds
                        project.referenceTime = seconds
                        project.referenceDate = .now
                        project.playbackRate = isRendering ? rate : 0.0
                        if subtitleText != project.currentSubtitleText {
                            project.currentSubtitleText = subtitleText
                        }
                    }
                    try? await Task.sleep(nanoseconds: 16_000_000) // ~60 FPS polling for ultra-responsive timing
                }
            }
        }
    }

    func setupFrameRateDetection(url: URL, engine: PlayerEngine) {
        Task {
            if engine is AVFoundationEngine {
                let asset = AVURLAsset(url: url)
                var fps: Float = 30.0
                var naturalSize: CGSize = .zero
                var isAudio = false
                do {
                    let videoTracks = try await asset.loadTracks(withMediaType: .video)
                    if let videoTrack = videoTracks.first {
                        fps = try await videoTrack.load(.nominalFrameRate)
                        naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
                    } else {
                        isAudio = true
                    }
                } catch {
                    isAudio = true
                }

                let roundedFPS: Double
                if isAudio { roundedFPS = 50.0 }
                else if abs(fps - 23.976) < 0.01 { roundedFPS = 23.976 }
                else if abs(fps - 29.97) < 0.01 { roundedFPS = 29.97 }
                else if abs(fps - 59.94) < 0.01 { roundedFPS = 59.94 }
                else { roundedFPS = Double(fps) }

                await MainActor.run {
                    project.isAudioOnly = isAudio
                    project.videoFrameRate = roundedFPS
                    if naturalSize != .zero {
                        project.videoSize = naturalSize
                        #if os(macOS)
                        VideoProperties.shared.adjustWindowForVideoSize(naturalSize, isAudioOnly: isAudio)
                        #endif
                    }
                    project.resnapAllItems()
                    setupTimeObserver()
                }
            } else {
                let size = await engine.videoSize
                let frameRate = await engine.fps
                await MainActor.run {
                    project.isAudioOnly = (size == .zero)
                    project.videoFrameRate = frameRate
                    if size != .zero {
                        project.videoSize = size
                        #if os(macOS)
                        VideoProperties.shared.adjustWindowForVideoSize(size, isAudioOnly: project.isAudioOnly)
                        #endif
                    }
                    project.resnapAllItems()
                    setupTimeObserver()
                }
            }
        }
    }

    // MARK: - Scrub Task

    func setupScrubTask() {
        scrubTask?.cancel()

        let stream = AsyncStream<Double> { cont in
            self.scrubContinuation = cont
        }

        scrubTask = Task { [weak project, weak engine] in
            guard let project, let eng = engine else { return }
            var lastPreviewSeekTime: Double?
            var pendingTime: Double?
            var isProcessing = false

            for await time in stream {
                guard !Task.isCancelled else { break }
                let shouldPreview = await MainActor.run {
                    project.isScrubbing
                }
                guard shouldPreview else {
                    lastPreviewSeekTime = nil
                    continue
                }

                pendingTime = time

                guard !isProcessing else { continue }
                isProcessing = true

                while let currentPending = pendingTime {
                    pendingTime = nil

                    if let lastPreviewSeekTime, abs(lastPreviewSeekTime - currentPending) < 0.001 {
                        // skip
                    } else {
                        lastPreviewSeekTime = currentPending
                        _ = await eng.seekVideoFrameOnly(to: currentPending)
                    }

                    // Throttle delay: wait 30ms before processing the next item
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                isProcessing = false
            }
        }
    }
}
