//
//  VideoPlayerView.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/16.
//

import SwiftUI
import AVFoundation
import CoreImage
import UniformTypeIdentifiers
import AsyncAlgorithms

// MARK: - VideoPlayerView

struct VideoPlayerView: View {
    @ObservedObject var project: SubtitleProject
    @State private var player = AVPlayer()
    @State private var timeObserverToken: Any?
    @State private var isSeeking = false
    @State private var scrubContinuation: AsyncStream<Double>.Continuation?
    @State private var scrubTask: Task<Void, Never>?
    var onImportMedia: () -> Void

    private var currentSubtitle: SubtitleItem? {
        // 🚀 Real-time timing preview: If there is an active slap timing session (J/K pressed down), prioritize showing it!
        if let activeID = project.activeSlapSubtitleID,
           let activeItem = project.items.first(where: { $0.id == activeID }) {
            return activeItem
        }
        
        // Otherwise, match the subtitle segment according to the current player time
        return project.items.first { item in
            if let start = item.startTime, let end = item.endTime {
                return project.currentTime >= start && project.currentTime <= end
            }
            return false
        }
    }

    var body: some View {
        ZStack {
            if project.videoURL != nil {
                ZStack(alignment: .bottom) {
                    CustomAVPlayerView(player: player)
                        .contentShape(Rectangle())
                        #if os(iOS)
                        .onTapGesture(count: 2) {
                            togglePlay()
                        }
                        #endif
                    
                    if project.showSoftSubtitles, let currentSub = currentSubtitle {
                        Text(currentSub.text)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1.5)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.65))
                            .cornerRadius(8)
                            .padding(.bottom, 40)
                            .id(currentSub.id)
                            .transition(.opacity.animation(.easeInOut(duration: 0.08)))
                    }
                }
                .onAppear { setupPlayer(url: project.videoURL) }
                .onChange(of: project.videoURL) { _, newURL in setupPlayer(url: newURL) }
                .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in togglePlay() }
                .onReceive(NotificationCenter.default.publisher(for: .seekDelta)) { notification in
                    if let delta = notification.object as? Double {
                        seekDelta(delta)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .changePlaybackSpeed)) { notification in
                    if let speed = notification.object as? Double {
                        changeSpeed(speed)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .requestCurrentTime)) { _ in
                    project.markCurrentTime(player.currentTime().seconds)
                }
                .onChange(of: project.currentTime) { _, newTime in
                    // Only sync player if the change came from user scrubbing or tap-seek
                    guard project.isUserSeekingTimeline || project.isScrubbing else { return }
                    
                    if project.isScrubbing {
                        // 🚀 Dragging: Yield to the non-blocking AsyncSequence queue to be throttled!
                        scrubContinuation?.yield(newTime)
                    } else {
                        // 🎯 One-off Tap Seek: Zero-tolerance exact frame seek for pixel-perfect alignment!
                        guard !isSeeking else { return } // Prevent infinite recursive loops
                        isSeeking = true
                        project.isSeeking = true
                        
                        let target = CMTime(seconds: newTime, preferredTimescale: 600)
                        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                            if finished {
                                DispatchQueue.main.async {
                                    isSeeking = false
                                    project.isSeeking = false
                                    project.isUserSeekingTimeline = false
                                }
                            }
                        }
                    }
                }
                .onChange(of: project.isScrubbing) { _, isScrubbing in
                    if !isScrubbing {
                        // 🎯 Dragging ended: Perform a precise zero-tolerance seek to lock in the final frame!
                        isSeeking = true
                        project.isSeeking = true
                        
                        let target = CMTime(seconds: project.currentTime, preferredTimescale: 600)
                        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                            if finished {
                                DispatchQueue.main.async {
                                    isSeeking = false
                                    project.isSeeking = false
                                    project.isUserSeekingTimeline = false
                                }
                            }
                        }
                    }
                }
            } else {
                emptyState
            }
        }
        .onAppear {
            setupScrubTask()
        }
        .onDisappear {
            scrubTask?.cancel()
            scrubTask = nil
        }
        .onDrop(of: [.movie, .video, .fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    Task { @MainActor in
                        project.videoURL = url
                    }
                }
            }
            return true
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ZStack {
            #if os(macOS)
            VisualEffectView(material: .underPageBackground, blendingMode: .behindWindow)
            #else
            VisualEffectView(style: .systemMaterial)
            #endif
            VStack(spacing: 20) {
                Image(systemName: "video.and.waveform")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    Text("No Media").font(.title3.bold())
                    Text("Drop a video or audio file here, or click to import")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Button(action: onImportMedia) { Label("Import Media…", systemImage: "plus.circle") }.buttonStyle(.borderedProminent)
            }
            .padding(40)
        }
    }

    // MARK: - Player Setup

    private func setupPlayer(url: URL?) {
        guard let url = url else { return }

        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: playerItem)

        // Asynchronously inspect tracks and load nominal frame rate
        Task {
            var fps: Float = 30.0
            var isAudio = false
            do {
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                if let videoTrack = videoTracks.first {
                    fps = try await videoTrack.load(.nominalFrameRate)
                } else {
                    isAudio = true
                }
            } catch {
                print("Failed to read nominal frame rate: \(error)")
                isAudio = true
            }
            
            // Standard broadcast frame rate adjustments
            let roundedFPS: Double
            if isAudio {
                roundedFPS = 50.0
            } else {
                if abs(fps - 23.976) < 0.01 {
                    roundedFPS = 23.976
                } else if abs(fps - 29.97) < 0.01 {
                    roundedFPS = 29.97
                } else if abs(fps - 59.94) < 0.01 {
                    roundedFPS = 59.94
                } else {
                    roundedFPS = Double(fps)
                }
            }
            
            await MainActor.run {
                project.isAudioOnly = isAudio
                project.videoFrameRate = roundedFPS
                
                // Re-register periodic time observer to match the detected frame rate (up to 60Hz)
                if let oldToken = timeObserverToken {
                    player.removeTimeObserver(oldToken)
                    timeObserverToken = nil
                }
                
                let targetTimescale = Int(min(60.0, max(24.0, roundedFPS.rounded())))
                
                timeObserverToken = player.addPeriodicTimeObserver(
                    forInterval: CMTime(value: 1, timescale: CMTimeScale(targetTimescale)),
                    queue: .main
                ) { [weak project] time in
                    guard let project else { return }
                    let seconds = time.seconds
                    let rate = Double(player.rate)
                    MainActor.assumeIsolated {
                        guard !project.isSeeking && !project.isScrubbing else { return }
                        withAnimation(.none) {
                            project.currentTime = seconds
                            project.referenceTime = seconds
                            project.referenceDate = .now
                            project.playbackRate = rate
                        }
                    }
                }
            }
        }
    }

    private func setupScrubTask() {
        scrubTask?.cancel()
        
        let stream = AsyncStream<Double> { cont in
            self.scrubContinuation = cont
        }
        
        scrubTask = Task { [weak project, weak player] in
            guard let project, let player else { return }
            for await time in stream._throttle(for: Duration.milliseconds(30), latest: true) {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard project.isScrubbing else { return }
                    let target = CMTime(seconds: time, preferredTimescale: 600)
                    player.seek(
                        to: target,
                        toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
                        toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)
                    )
                }
            }
        }
    }

    private func togglePlay() {
        if player.rate == 0 {
            player.play()
            player.rate = Float(project.targetSpeed)
        } else {
            player.pause()
        }
        project.playbackRate = Double(player.rate)
        project.referenceTime = player.currentTime().seconds
        project.referenceDate = .now
    }

    private func seekDelta(_ delta: Double) {
        let currentTime = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        let targetTime = max(0, (duration.isNaN || duration <= 0) ? currentTime + delta : min(duration, currentTime + delta))
        
        isSeeking = true
        project.isSeeking = true
        let target = CMTime(seconds: targetTime, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            if finished {
                DispatchQueue.main.async {
                    isSeeking = false
                    project.isSeeking = false
                    project.currentTime = targetTime
                    project.referenceTime = targetTime
                    project.referenceDate = .now
                }
            }
        }
    }

    private func changeSpeed(_ speed: Double) {
        project.targetSpeed = speed
        let isPlaying = player.rate != 0 || project.playbackRate != 0
        if isPlaying {
            player.rate = Float(speed)
        }
        project.playbackRate = isPlaying ? speed : 0.0
        project.referenceTime = player.currentTime().seconds
        project.referenceDate = .now
    }
}
