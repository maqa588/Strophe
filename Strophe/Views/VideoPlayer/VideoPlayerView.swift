import SwiftUI
import AVFoundation
import CoreImage
import UniformTypeIdentifiers

struct VideoPlayerView: View {
    @ObservedObject var project: SubtitleProject
    @State var timeObserverPlayer: AVPlayer?
    @State var timeObserverToken: Any?
    @State var timeObserverTask: Task<Void, Never>? = nil
    @State private var isSeeking = false
    @State private var scrubResumeRate: Double?
    @State var scrubContinuation: AsyncStream<Double>.Continuation?
    @State var scrubTask: Task<Void, Never>?
    @State var engine: PlayerEngine?
    @State var currentURL: URL? = nil
    @State var setupGeneration: UInt = 0
    @State var setupTask: Task<Void, Never>? = nil
    @State var showingCompatibilityAlert = false
    @State var isRemoteVolumeAlert = false
    @State var pendingCompatibilityURL: URL? = nil
    @State var incompatibleFormatName: String = ""
    @State private var isShowingReplaceMedia = false

    var onImportMedia: () -> Void

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
                        ZStack {
                            NativePlayerView(engine: engine)

                            // Subtitle overlay — stable view, never destroyed/recreated during playback.
                            // Hard preview takes visual precedence so the two preview modes do not double-render.
                            if project.showHardSubtitles {
                                HardSubtitleOverlayView(project: project)
                            } else if project.showSoftSubtitles {
                                SubtitleOverlayView(project: project)
                            }
                        }
                        .aspectRatio(aspect, contentMode: .fit)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { project.togglePlayback() }
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
                .stropheOnChange(of: project.isUserSeekingTimeline) { isSeekingTimeline in
                    guard isSeekingTimeline else { return }
                    Task { @MainActor in
                        await Task.yield()
                        guard !project.isScrubbing else {
                            project.isUserSeekingTimeline = false
                            return
                        }
                        guard !isSeeking else { return }
                        isSeeking = true
                        project.isSeeking = true
                        seekEngine(to: project.currentTime, resumeRate: nil) {
                            isSeeking = false
                            project.isSeeking = false
                            project.isUserSeekingTimeline = false
                        }
                    }
                }
                .stropheOnChange(of: project.isScrubbing) { isScrubbing in
                    if isScrubbing {
                        let activeRate = engine?.rate ?? project.playbackRate
                        scrubResumeRate = activeRate > 0 ? activeRate : nil
                        project.playbackRate = 0
                        project.referenceTime = project.currentTime
                        project.referenceDate = .now
                    } else {
                        let resumeRate = scrubResumeRate
                        scrubResumeRate = nil
                        isSeeking = true
                        project.isSeeking = true
                        seekEngine(to: project.currentTime, resumeRate: resumeRate) {
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
            suspendPlayerObservers()
        }
        .stropheOnChange(of: project.videoURL) { newURL in
            setupPlayer(url: newURL)
        }
        .stropheOnChange(of: project.mediaLoadError) { newError in
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
        .alert(
            isRemoteVolumeAlert ? String(localized: "remote_file_loading_tip") : String(localized: "format_compatibility_notice"),
            isPresented: $showingCompatibilityAlert,
            presenting: incompatibleFormatName
        ) { format in
            Button(isRemoteVolumeAlert ? String(localized: "continue_import") : String(localized: "got_it"), role: .none) {
                if let url = pendingCompatibilityURL {
                    guard project.videoURL == url else {
                        pendingCompatibilityURL = nil
                        return
                    }
                    // Approved format or remote share - proceed to load the
                    // project-owned FFmpeg engine.
                    Task { @MainActor in
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
                        // Window adjustment will happen automatically in setupFrameRateDetection after size is fetched
                    }
                }
                pendingCompatibilityURL = nil
            }
            Button(isRemoteVolumeAlert ? String(localized: "cancel_import") : String(localized: "cancel_import_1"), role: .cancel) {
                // Restore previous valid URL, or nil if none was active
                project.videoURL = currentURL
                pendingCompatibilityURL = nil
            }
        } message: { format in
            if isRemoteVolumeAlert {
                Text(String(localized: "remote_network_playback_message"))
            } else {
                Text(String(localized: "您的设备对 \(format) 格式兼容性欠佳，在播放过程中可能会遇到一些性能问题。\n\n建议尽量使用 MP4、MOV、M4V、MP3、FLAC、M4A、AAC、ALAC 等推荐的视频、音频格式以获得最流畅的体验。"))
            }
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
        let time = engine?.currentTime ?? 0
        guard time.isFinite else { return project.currentTime }
        return time
    }

    // MARK: - Seeking via engine

    private func seekEngine(to time: Double, resumeRate: Double?, completion: @escaping () -> Void) {
        guard let eng = engine else { completion(); return }
        guard time.isFinite else { completion(); return }
        Task {
            let finished = await eng.seek(to: time)
            await MainActor.run {
                if let resumeRate, resumeRate > 0 {
                    eng.rate = resumeRate
                    project.playbackRate = resumeRate
                } else {
                    project.playbackRate = eng.rate
                }
                let resolvedTime = eng.currentTime
                if finished, resolvedTime.isFinite {
                    project.currentTime = resolvedTime
                    project.referenceTime = resolvedTime
                } else {
                    // The UI may already contain the requested scrub/click time.
                    // Roll it back to the engine clock when the seek was interrupted.
                    project.syncPlaybackClockFromEngine()
                }
                project.referenceDate = .now
                completion()
            }
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
                    Text("no_media").font(.title3.bold())
                    Text("drop_media_prompt")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Button(action: onImportMedia) { Label("import_media_ellipsis", systemImage: "plus.circle") }.buttonStyle(.borderedProminent)
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
                    Text(String(localized: "media_not_found")).font(.title3.bold())
                    Text(String(localized: "\"\(mediaName)\" could not be opened.\nPlease replace the media file below."))
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Button(action: { isShowingReplaceMedia = true }) {
                    Label(String(localized: "replace_media_ellipsis"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(40)
        }
    }

    // Setup, observer, and scrub methods are in VideoPlayerView+Setup.swift
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
