import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

enum WelcomeAction {
    case newProject
    case openMedia
    case importSubtitles
    case openProject
    case openRecent(WelcomeRecentProject)
}

struct WelcomeRouterView: View {
    @ObservedObject var project: SubtitleProject
    var opensEditorInPlace = true
    var openEditorWindow: (() -> Void)?

    @StateObject private var recentStore = WelcomeRecentProjectsStore()
    @State private var isShowingEditor = false
    @State private var isShowingMediaImporter = false
    @State private var isShowingSubtitleImporter = false
    @State private var isShowingProjectImporter = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if opensEditorInPlace && isShowingEditor {
                ContentView(project: project)
            } else {
                WelcomeView(
                    projects: recentStore.projects,
                    isOpeningProject: project.isLoadingProject && project.mediaLoadError == nil,
                    onAction: handleAction,
                    onRemoveRecentProject: { project in
                        recentStore.remove(project)
                    },
                    onDeleteRecentProject: { project in
                        try recentStore.delete(project)
                    }
                )
            }
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingMediaImporter) {
            MediaDocumentPicker(
                allowedContentTypes: UTType.allMediaTypes,
                allowsMultipleSelection: false
            ) { result in
                isShowingMediaImporter = false
                handleMediaImport(result)
            }
        }
        .sheet(isPresented: $isShowingSubtitleImporter) {
            MediaDocumentPicker(
                allowedContentTypes: UTType.allSubtitleTypes,
                allowsMultipleSelection: false
            ) { result in
                isShowingSubtitleImporter = false
                handleSubtitleImport(result)
            }
        }
        .sheet(isPresented: $isShowingProjectImporter) {
            MediaDocumentPicker(
                allowedContentTypes: [.stropheProject],
                allowsMultipleSelection: false
            ) { result in
                isShowingProjectImporter = false
                handleProjectImport(result)
            }
        }
        #else
        .fileImporter(
            isPresented: $isShowingMediaImporter,
            allowedContentTypes: UTType.allMediaTypes,
            allowsMultipleSelection: false,
            onCompletion: handleMediaImport
        )
        .fileImporter(
            isPresented: $isShowingSubtitleImporter,
            allowedContentTypes: UTType.allSubtitleTypes,
            allowsMultipleSelection: false,
            onCompletion: handleSubtitleImport
        )
        .fileImporter(
            isPresented: $isShowingProjectImporter,
            allowedContentTypes: [.stropheProject],
            allowsMultipleSelection: false,
            onCompletion: handleProjectImport
        )
        #endif
        .alert(
            String(localized: "operation_cannot_be_completed"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(String(localized: "ok"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            recentStore.reload()
        }
        .onOpenURL { url in
            handleExternalOpen(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheNewProject)) { _ in
            guard !isEditorPresented else { return }
            handleAction(.newProject)
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheImportScriptFile)) { _ in
            guard !isEditorPresented else { return }
            handleAction(.importSubtitles)
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheOpenProject)) { _ in
            guard !isEditorPresented else { return }
            handleAction(.openProject)
        }
    }

    private var isEditorPresented: Bool {
        opensEditorInPlace && isShowingEditor
    }

    private func handleAction(_ action: WelcomeAction) {
        switch action {
        case .newProject:
            project.createNewProject()
            revealEditor()
        case .openMedia:
            isShowingMediaImporter = true
        case .importSubtitles:
            isShowingSubtitleImporter = true
        case .openProject:
            isShowingProjectImporter = true
        case .openRecent(let recentProject):
            openRecentProject(recentProject)
        }
    }

    private func handleMediaImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        project.importMediaAsNewProject(from: url)
        revealEditor()
    }

    private func handleSubtitleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        do {
            let rawText = try SubtitleEngine.loadRawText(from: url)
            project.importScript(rawText)
            revealEditor()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleProjectImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        openProject(url)
    }

    private func handleExternalOpen(_ url: URL) {
        if url.pathExtension.lowercased() == "strophe" {
            openProject(url)
        } else {
            project.importMediaAsNewProject(from: url)
            revealEditor()
        }
    }

    private func openRecentProject(_ recentProject: WelcomeRecentProject) {
        // Try resolving the security-scoped bookmark first (needed for external drives / sandboxed access)
        let resolvedURL = recentProject.resolveBookmark() ?? recentProject.url
        openProject(resolvedURL)
    }

    private func openProject(_ url: URL) {
        project.isLoadingProject = true
        Task {
            defer { project.isLoadingProject = false }
            do {
                try await project.importStropheProject(from: url)
                recentStore.remember(url)
                revealEditor()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func revealEditor() {
        if opensEditorInPlace {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                isShowingEditor = true
            }
        } else {
            openEditorWindow?()
        }
    }
}

#if os(macOS)
struct MacWelcomeSceneView: View {
    @ObservedObject var project: SubtitleProject
    @Environment(\.openWindow) private var openWindow
    @State private var window: NSWindow?

    var body: some View {
        ZStack {
            WelcomeRouterView(
                project: project,
                opensEditorInPlace: false
            ) {
                openWindow(id: "editor")
                DispatchQueue.main.async {
                    window?.close()
                }
            }
            .frame(width: 920, height: 620)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                PixelStyleCloseButton {
                    window?.close()
                }
                .padding(.leading, 18)
                .padding(.top, 18)
            }
        }
        .frame(width: 920, height: 620)
        .background(Color.clear)
        .ignoresSafeArea()
        .background(WindowAccessor { window = $0 })
        .preferredColorScheme(.dark)
    }
}

private struct PixelStyleCloseButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isHovering ? Color.white.opacity(0.22) : Color.white.opacity(0.13))
                    .frame(width: 20, height: 20)

                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.black.opacity(isHovering ? 0.7 : 0.48))
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(String(localized: "close"))
    }
}

private struct WindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                configure(window)
                onResolve(window)
            }
        }
    }

    private func configure(_ window: NSWindow) {
        window.styleMask = [.borderless]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView?.layer?.cornerRadius = 26
        window.contentView?.layer?.cornerCurve = .continuous
        window.contentView?.layer?.masksToBounds = true
        window.contentView?.superview?.wantsLayer = true
        window.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor
    }
}
#endif
