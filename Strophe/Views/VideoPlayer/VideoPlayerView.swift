import SwiftUI
import AVFoundation
import CoreImage
import UniformTypeIdentifiers
import AsyncAlgorithms

struct VideoPlayerView: View, Equatable {
    @ObservedObject var project: SubtitleProject
    @State private var timeObserverPlayer: AVPlayer?
    @State private var timeObserverToken: Any?
    @State private var timeObserverTask: Task<Void, Never>? = nil
    @State private var isSeeking = false
    @State private var scrubContinuation: AsyncStream<Double>.Continuation?
    @State private var scrubTask: Task<Void, Never>?
    @State private var engine: PlayerEngine?
    @State private var currentURL: URL? = nil
    @State private var showingCompatibilityAlert = false
    @State private var pendingCompatibilityURL: URL? = nil
    @State private var incompatibleFormatName: String = ""
    @State private var isShowingReplaceMedia = false

    var onImportMedia: () -> Void

    static func == (lhs: VideoPlayerView, rhs: VideoPlayerView) -> Bool {
        lhs.project === rhs.project &&
        lhs.project.videoURL == rhs.project.videoURL
    }

    var body: some View {
        ZStack {
            if let mediaError = project.mediaLoadError {
                mediaErrorState(mediaError)
            } else if project.videoURL != nil {
                ZStack {
                    Color.black
                    if let engine = engine {
                        let aspect = project.videoSize == .zero
                            ? 16.0 / 9.0
                            : project.videoSize.width / project.videoSize.height
                        NativePlayerView(engine: engine)
                            .aspectRatio(aspect, contentMode: .fit)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { project.togglePlayback() }
                    }

                    // Subtitle overlay — stable view, never destroyed/recreated during playback
                    if project.showSoftSubtitles {
                        SubtitleOverlayView(project: project)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .requestCurrentTime)) { _ in
                    project.markCurrentTime(currentEngineTime)
                }
                .onReceive(NotificationCenter.default.publisher(for: .stropheScrubTimeChanged)) { notification in
                    if let time = notification.object as? Double {
                        scrubContinuation?.yield(time)
                    }
                }
                .onChange(of: project.isUserSeekingTimeline) { _, isSeekingTimeline in
                    guard isSeekingTimeline else { return }
                    guard !project.isScrubbing else { return }
                    guard !isSeeking else { return }
                    isSeeking = true
                    project.isSeeking = true
                    seekEngine(to: project.currentTime) {
                        isSeeking = false
                        project.isSeeking = false
                        project.isUserSeekingTimeline = false
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
        .onAppear {
            setupScrubTask()
            setupPlayer(url: project.videoURL)
        }
        .onDisappear {
            scrubTask?.cancel()
            scrubTask = nil
            setupPlayer(url: nil)
        }
        .onChange(of: project.videoURL) { _, newURL in
            setupPlayer(url: newURL)
        }
        .onChange(of: project.mediaLoadError) { _, newError in
            if newError != nil {
                setupPlayer(url: nil)
            }
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
        .alert(String(localized: "格式兼容性提示"), isPresented: $showingCompatibilityAlert, presenting: incompatibleFormatName) { format in
            Button("我知道了", role: .none) {
                if let url = pendingCompatibilityURL {
                    // Approved incompatible format — proceed to load FFmpeg engine
                    currentURL = url
                    let ffmpegEngine = FFmpegEngine()
                    engine = ffmpegEngine
                    project.activeEngine = ffmpegEngine
                    print("🎬 Using engine: FFmpegEngine (\(type(of: ffmpegEngine))) for \(url.lastPathComponent)")
                    Task {
                        await ffmpegEngine.load(url: url)
                        setupFrameRateDetection(url: url, engine: ffmpegEngine)
                        // Window adjustment will happen automatically in setupFrameRateDetection after size is fetched
                    }
                }
                pendingCompatibilityURL = nil
            }
            Button("放弃导入", role: .cancel) {
                // Restore previous valid URL, or nil if none was active
                project.videoURL = currentURL
                pendingCompatibilityURL = nil
            }
        } message: { format in
            Text("您的设备对 \(format) 格式兼容性欠佳，在播放过程中可能会遇到一些性能问题。\n\n建议尽量使用 MP4、MOV、M4V、MP3、FLAC、M4A、AAC、ALAC 等推荐的视频、音频格式以获得最流畅的体验。")
        }
        .fileImporter(
            isPresented: $isShowingReplaceMedia,
            allowedContentTypes: UTType.allMediaTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            project.replaceMedia(with: url)
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
    
    // MARK: - Media Error State
    
    private func mediaErrorState(_ mediaName: String) -> some View {
        ZStack {
            #if os(macOS)
            VisualEffectView(material: .underPageBackground, blendingMode: .behindWindow)
            #else
            VisualEffectView(style: .systemMaterial)
            #endif
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(.orange)
                VStack(spacing: 6) {
                    Text(String(localized: "Media Not Found")).font(.title3.bold())
                    Text(String(localized: "\"\(mediaName)\" could not be opened.\nPlease replace the media file below."))
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Button(action: { isShowingReplaceMedia = true }) {
                    Label(String(localized: "Replace Media…"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(40)
        }
    }

    // MARK: - Player Setup

    private func setupPlayer(url: URL?) {
        guard let url = url else {
            // Stop old engine when clearing
            engine?.stop()
            engine = nil
            currentURL = nil
            
            if let token = timeObserverToken {
                timeObserverPlayer?.removeTimeObserver(token)
                timeObserverToken = nil
                timeObserverPlayer = nil
            }
            timeObserverTask?.cancel()
            timeObserverTask = nil
            return
        }

        // Guard against duplicate/re-entrant setup for the same URL
        if currentURL == url { return }
        
        // Guard if we are currently prompting compatibility check for this exact URL
        if pendingCompatibilityURL == url { return }
        
        // 🌟 Check if there is already an active engine for this video in the project context.
        // This occurs when SwiftUI transitions between horizontal size classes (compact/regular)
        // or layout orientations, which recreates the VideoPlayerView struct.
        if let existingEngine = project.activeEngine {
            self.engine = existingEngine
            self.currentURL = url
            setupTimeObserver()
            setupScrubTask()
            return
        }
        
        // *** CRITICAL: Stop the old engine before creating a new one! ***
        // Without this, old FFmpegEngine instances keep their decode loops,
        // display links, timers, and audio engines running as zombies,
        // consuming CPU/GPU/memory and degrading FPS with each switch.
        engine?.stop()
        engine = nil

        if let token = timeObserverToken {
            timeObserverPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
            timeObserverPlayer = nil
        }
        timeObserverTask?.cancel()
        timeObserverTask = nil
        project.videoSize = .zero  // reset so aspectRatio updates once new size is detected

        Task { @MainActor in
            let result = await FormatDetector.shared.detect(url: url)

            if result.isAVFoundationCompatible {
                currentURL = url
                let avEngine = AVFoundationEngine()
                engine = avEngine
                project.activeEngine = avEngine
                print("🎬 Using engine: AVFoundationEngine (\(type(of: avEngine))) for \(url.lastPathComponent)")
                await avEngine.load(url: url)

                setupFrameRateDetection(url: url, engine: avEngine)
                
                // Window adjustment will happen automatically in setupFrameRateDetection after size is fetched
            } else {
                // Not native AVFoundation compatible (MKV, WebM, RMVB, AVI, FLV etc.)
                // Show compatibility check alert before loading!
                self.incompatibleFormatName = url.pathExtension.uppercased()
                self.pendingCompatibilityURL = url
                self.showingCompatibilityAlert = true
            }
        }
    }

    private func setupTimeObserver() {
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
                MainActor.assumeIsolated {
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

    private func setupFrameRateDetection(url: URL, engine: PlayerEngine) {
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
                await eng.seekVideoFrameOnly(to: time)
            }
        }
    }

}

// MARK: - Subtitle Overlay (leaf view — only reads pre-computed text, zero traversal)
struct SubtitleOverlayView: View {
    @ObservedObject var project: SubtitleProject
    
    var body: some View {
        VStack {
            Spacer()
            if let text = project.currentSubtitleText {
                Text(text)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1.5)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.65))
                    .cornerRadius(8)
                    .padding(.bottom, 40)
                    .animation(.easeInOut(duration: 0.08), value: text)
            }
        }
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
#else
struct NativePlayerView: UIViewRepresentable {
    let engine: PlayerEngine

    func makeUIView(context: Context) -> UIView {
        return engine.playerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
