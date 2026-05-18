import SwiftUI
import AVFoundation
import CoreImage
import UniformTypeIdentifiers
import AsyncAlgorithms

struct VideoPlayerView: View {
    @ObservedObject var project: SubtitleProject
    @State private var timeObserverPlayer: AVPlayer?
    @State private var timeObserverToken: Any?
    @State private var isSeeking = false
    @State private var scrubContinuation: AsyncStream<Double>.Continuation?
    @State private var scrubTask: Task<Void, Never>?
    @State private var engine: PlayerEngine?
    @State private var currentURL: URL? = nil

    var onImportMedia: () -> Void

    private var currentSubtitle: SubtitleItem? {
        if let activeID = project.activeSlapSubtitleID,
           let activeItem = project.items.first(where: { $0.id == activeID }) {
            return activeItem
        }

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
                ZStack {
                    Color.black
                    if let engine = engine {
                        let aspect = project.videoSize == .zero
                            ? 16.0 / 9.0
                            : project.videoSize.width / project.videoSize.height
                        #if os(macOS)
                        NativePlayerView(engine: engine)
                            .aspectRatio(aspect, contentMode: .fit)
                        #else
                        if let avEngine = engine as? AVFoundationEngine {
                            CustomAVPlayerView(player: avEngine.playerRef)
                                .aspectRatio(aspect, contentMode: .fit)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { togglePlay() }
                        }
                        #endif
                    }

                    // Subtitle overlay pinned to bottom of the video area
                    if project.showSoftSubtitles, let currentSub = currentSubtitle {
                        VStack {
                            Spacer()
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
                }
                .onAppear { setupPlayer(url: project.videoURL) }
                .onChange(of: project.videoURL) { _, newURL in setupPlayer(url: newURL) }
                .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in togglePlay() }
                .onReceive(NotificationCenter.default.publisher(for: .seekDelta)) { notification in
                    if let delta = notification.object as? Double { seekDelta(delta) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .changePlaybackSpeed)) { notification in
                    if let speed = notification.object as? Double { changeSpeed(speed) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .requestCurrentTime)) { _ in
                    project.markCurrentTime(currentEngineTime)
                }
                .onChange(of: project.currentTime) { _, newTime in
                    guard !project.isSeeking && !project.isScrubbing else { return }
                    guard project.isUserSeekingTimeline || project.isScrubbing else { return }

                    if project.isScrubbing {
                        scrubContinuation?.yield(newTime)
                    } else {
                        guard !isSeeking else { return }
                        isSeeking = true
                        project.isSeeking = true
                        seekEngine(to: newTime) {
                            isSeeking = false
                            project.isSeeking = false
                            project.isUserSeekingTimeline = false
                        }
                    }
                }
                .onChange(of: project.isScrubbing) { _, isScrubbing in
                    if !isScrubbing {
                        isSeeking = true
                        project.isSeeking = true
                        seekEngine(to: project.currentTime) {
                            isSeeking = false
                            project.isSeeking = false
                            project.isUserSeekingTimeline = false
                        }
                    }
                }
            } else {
                emptyState
            }
        }
        .onAppear { setupScrubTask() }
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

    private var currentEngineTime: Double {
        engine?.currentTime ?? 0
    }

    // MARK: - Seeking via engine

    private func seekEngine(to time: Double, completion: @escaping () -> Void) {
        guard let eng = engine else { completion(); return }
        Task {
            await eng.seek(to: time)
            await MainActor.run { completion() }
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
        guard let url = url else {
            currentURL = nil
            return
        }

        // Guard against duplicate/re-entrant setup for the same URL
        if currentURL == url { return }
        currentURL = url

        if let token = timeObserverToken {
            timeObserverPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
            timeObserverPlayer = nil
        }
        project.videoSize = .zero  // reset so aspectRatio updates once new size is detected

        Task { @MainActor in
            let result = await FormatDetector.shared.detect(url: url)

            if result.isAVFoundationCompatible {
                let avEngine = AVFoundationEngine()
                engine = avEngine
                print("🎬 Using engine: AVFoundationEngine (\(type(of: avEngine))) for \(url.lastPathComponent)")
                await avEngine.load(url: url)

                setupTimeObserver(avEngine: avEngine)
                setupFrameRateDetection(url: url, avEngine: avEngine)
            }

            #if os(macOS)
            VideoProperties.shared.adjustWindowForVideo(url: url, isAudioOnly: project.isAudioOnly)
            #endif
        }
    }

    private func setupTimeObserver(avEngine: AVFoundationEngine) {
        let playerRef = avEngine.playerRef
        if let oldToken = timeObserverToken {
            timeObserverPlayer?.removeTimeObserver(oldToken)
            timeObserverToken = nil
            timeObserverPlayer = nil
        }

        let fps = Int(min(60, max(24, project.videoFrameRate.rounded())))
        timeObserverPlayer = playerRef
        timeObserverToken = playerRef.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: CMTimeScale(fps)),
            queue: .main
        ) { [weak project, weak playerRef] time in
            guard let project, let playerRef else { return }
            let seconds = time.seconds
            let rate = Double(playerRef.rate)
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

    private func setupFrameRateDetection(url: URL, avEngine: AVFoundationEngine) {
        Task {
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
                if naturalSize != .zero { project.videoSize = naturalSize }
                project.resnapAllItems()
                setupTimeObserver(avEngine: avEngine)
            }
        }
    }



    // MARK: - Scrub Task

    private func setupScrubTask() {
        scrubTask?.cancel()

        let stream = AsyncStream<Double> { cont in
            self.scrubContinuation = cont
        }

        scrubTask = Task { [weak project, weak engine] in
            guard let project, let eng = engine else { return }
            for await time in stream._throttle(for: Duration.milliseconds(30), latest: true) {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard project.isScrubbing else { return }
                }
                await eng.seek(to: time)
            }
        }
    }

    // MARK: - Playback Controls

    private func togglePlay() {
        guard let eng = engine else { return }
        if eng.rate == 0 {
            eng.rate = project.targetSpeed
        } else {
            eng.rate = 0.0
        }
        project.playbackRate = eng.rate
        project.referenceTime = eng.currentTime
        project.referenceDate = .now
    }

    private func seekDelta(_ delta: Double) {
        guard let eng = engine else { return }
        let currentTime = eng.currentTime
        let duration = eng.duration
        let targetTime = max(0, (duration.isNaN || duration <= 0) ? currentTime + delta : min(duration, currentTime + delta))

        isSeeking = true
        project.isSeeking = true
        Task { @MainActor in
            await eng.seek(to: targetTime)
            isSeeking = false
            project.isSeeking = false
            project.currentTime = targetTime
            project.referenceTime = targetTime
            project.referenceDate = .now
        }
    }

    private func changeSpeed(_ speed: Double) {
        project.targetSpeed = speed
        let isPlaying = engine?.rate != 0 || project.playbackRate != 0
        if isPlaying {
            engine?.rate = speed
        }
        project.playbackRate = isPlaying ? speed : 0.0
        project.referenceTime = engine?.currentTime ?? 0
        project.referenceDate = .now
    }
}

#if os(macOS)
struct NativePlayerView: NSViewRepresentable {
    let engine: PlayerEngine

    func makeNSView(context: Context) -> NSView {
        return engine.playerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
