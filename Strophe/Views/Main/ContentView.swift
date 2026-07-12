//
//  ContentView.swift
//  Strophe
//
//  导航架构（Telegram 风格，自绘，所有平台统一）：
//
//  iPad / macOS（宽屏）：
//    ┌──────────────┬────────────────────────┐
//    │ NavigationStack            │ NavigationStack        │
//    │ (ScriptListView /          │ MainContentView        │
//    │  SettingsPlaceholder)      │ (视频 + 波形)           │
//    │                            │                        │
//    │ [自绘 TabBar: 编辑器 | 设置]│                        │
//    └──────────────┴────────────────────────┘
//
//  iPhone（窄屏，编辑器 tab 外）：
//    NavigationStack(当前 tab 内容)
//    [自绘 TabBar: 文稿 | 编辑器 | 设置]
//
//  iPhone（编辑器 tab）：
//    NavigationStack(MainContentView)  ← 全屏，TabBar 不出现
//    左上 ‹ 按钮返回文稿 tab
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var project: SubtitleProject
    var embedsCompactEditorInNavigationStack = true
    @Environment(\.horizontalSizeClass) var sizeClass

    @State var selectedTab: StropheTab = .editor
    @State var settingsPath: [SettingsRoute] = []

    @State var isShowingSaveStrophe = false
    @State var saveStropheDefaultName = "project.strophe"
    @State var cachedProjectURLPendingPromotion: URL? = nil
    @State private var isShowingOpenProject = false
    @State private var isShowingReplaceMedia = false
    @State private var isShowingSubtitleImporter = false
    @State var isShowingNewProjectAlert = false
    @State var fileActionError: String? = nil
    @State var isShowingOverwriteAlert = false
    @State var pendingStropheURL: URL? = nil
    @State var isShowingRestoreTimeAlert = false
    @State var pendingRestoreTime: Double = 0
    #if os(macOS)
    @State private var isShowingSaveOnQuitAlert = false
    @State private var isQuittingAfterSave = false
    @State var keyboardMonitor: Any?
    #endif

    var usesLiquidGlassNavigation: Bool {
        if #available(anyAppleOS 26.0, *) { true } else { false }
    }

    @ViewBuilder
    private var editorLayout: some View {
        Group {
            if sizeClass == .compact {
                compactLayout       // iPhone
            } else {
                wideLayout          // iPad / macOS
            }
        }
        .tint(Color.stropheAccent)
        .stropheHardwareKeyboardMonitor(project: project)
        .overlay {
            if project.isLoadingProject && project.mediaLoadError == nil {
                projectLoadingOverlay
            }
        }
        .overlay {
            if isShowingRestoreTimeAlert {
                restoreTimeOverlay
            }
        }
    }

    private var fileImportingEditor: some View {
        editorLayout
        .fileImporter(
            isPresented: $isShowingOpenProject,
            allowedContentTypes: [.stropheProject],
            allowsMultipleSelection: false
        ) { handleOpenProject($0) }
        .fileImporter(
            isPresented: $isShowingReplaceMedia,
            allowedContentTypes: UTType.allMediaTypes,
            allowsMultipleSelection: false,
            onCompletion: handleReplaceMedia
        )
        .fileImporter(
            isPresented: $isShowingSubtitleImporter,
            allowedContentTypes: UTType.allSubtitleTypes,
            allowsMultipleSelection: false,
            onCompletion: handleSubtitleImport
        )
    }

    var body: some View {
        fileImportingEditor
        .fileExporter(
            isPresented: $isShowingSaveStrophe,
            document: project.stropheDocument,
            contentType: .stropheProject,
            defaultFilename: saveStropheDefaultName
        ) { result in
            if case .success(let url) = result {
                Task {
                    var didSave = false
                    do {
                        try await project.saveStrophe(to: url)
                        didSave = true
                        WelcomeRecentProjectsStore.remember(url)
                        if let cachedURL = cachedProjectURLPendingPromotion,
                           cachedURL.standardizedFileURL != url.standardizedFileURL {
                            WelcomeRecentProjectsStore.remove(cachedURL, deletingCachedFile: true)
                        }
                        project.startAutoSave()
                    } catch {
                        print("⚠️ Failed to save Strophe project: \(error.localizedDescription)")
                    }
                    cachedProjectURLPendingPromotion = nil
                    #if os(macOS)
                    if isQuittingAfterSave {
                        isQuittingAfterSave = false
                        if didSave {
                            project.markClean()
                            NSApplication.shared.reply(toApplicationShouldTerminate: true)
                        } else {
                            NSApplication.shared.reply(toApplicationShouldTerminate: false)
                        }
                    }
                    #endif
                }
            } else {
                #if os(macOS)
                if isQuittingAfterSave {
                    isQuittingAfterSave = false
                    NSApplication.shared.reply(toApplicationShouldTerminate: false)
                }
                #endif
                cachedProjectURLPendingPromotion = nil
            }
        }
        .alert(
            String(localized: "new_project_confirm"),
            isPresented: $isShowingNewProjectAlert
        ) {
            Button(String(localized: "new_project"), role: .destructive) {
                createNewProject()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "new_project_warning"))
        }
        .alert(
            String(localized: "overwrite_existing_subtitles"),
            isPresented: $isShowingOverwriteAlert
        ) {
            Button(String(localized: "overwrite"), role: .destructive) {
                if let url = pendingStropheURL {
                    Task {
                        await openProject(url)
                    }
                }
                pendingStropheURL = nil
            }
            Button(String(localized: "cancel"), role: .cancel) {
                pendingStropheURL = nil
            }
        } message: {
            Text(String(localized: "importing_this_project_file_will"))
        }
        .alert(
            String(localized: "operation_cannot_be_completed"),
            isPresented: Binding(
                get: { fileActionError != nil },
                set: { if !$0 { fileActionError = nil } }
            )
        ) {
            Button(String(localized: "ok"), role: .cancel) {
                fileActionError = nil
            }
        } message: {
            Text(fileActionError ?? "")
        }
        #if os(macOS)
        .alert(
            String.localizedStringWithFormat(
                String(localized: "save_project"),
                project.documentDisplayName
            ),
            isPresented: $isShowingSaveOnQuitAlert
        ) {
            Button(String(localized: "save")) {
                if let url = project.projectURL,
                   !SubtitleProject.isManagedProjectCacheURL(url) {
                    Task {
                        try? await project.saveStrophe(to: url)
                        WelcomeRecentProjectsStore.remember(url)
                        project.markClean()
                        NSApplication.shared.reply(toApplicationShouldTerminate: true)
                    }
                } else {
                    isQuittingAfterSave = true
                    presentSaveStropheExporter()
                }
            }
            Button(String(localized: "dont_save"), role: .destructive) {
                project.markClean()
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
            Button(String(localized: "cancel"), role: .cancel) {
                NSApplication.shared.reply(toApplicationShouldTerminate: false)
            }
        } message: {
            Text(String(localized: "unsaved_changes_will_be_lost"))
        }
        #endif
        .stropheOnChange(of: project.loadedPlayheadTime) { newValue in
            if let time = newValue {
                pendingRestoreTime = time
                isShowingRestoreTimeAlert = true
                project.loadedPlayheadTime = nil
            }
        }
        .onAppear {
            setupKeyboardMonitor()
        }
        #if os(macOS)
        .onDisappear {
            removeKeyboardMonitor()
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .stropheOpenProject)) { _ in
            isShowingOpenProject = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheNewProject)) { _ in
            requestNewProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheReplaceMedia)) { _ in
            isShowingReplaceMedia = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheImportScriptFile)) { _ in
            isShowingSubtitleImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheOpenProjectWithURL)) { notification in
            if let url = notification.object as? URL {
                handleOpenProject(.success([url]))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheSaveProject)) { _ in
            saveProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheSaveProjectAs)) { _ in
            saveProjectAs()
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .stropheShowSaveOnQuitAlert)) { _ in
            isShowingSaveOnQuitAlert = true
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .stropheShowAbout)) { _ in
            showAboutPage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheOpenModelSettings)) { notification in
            let route = notification.object as? SettingsRoute ?? .whisperConfig
            selectedTab = .settings
            DispatchQueue.main.async {
                settingsPath = [route]
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let togglePlayback      = Notification.Name("com.swiftsub.togglePlayback")
    static let requestCurrentTime  = Notification.Name("com.swiftsub.requestCurrentTime")
    static let seekDelta           = Notification.Name("com.swiftsub.seekDelta")
    static let changePlaybackSpeed = Notification.Name("com.swiftsub.changePlaybackSpeed")
}

// MARK: - Cross-platform navigation title helper

extension View {
    /// Sets a navigation title with inline display mode on iOS/iPadOS;
    /// on macOS `navigationBarTitleDisplayMode` does not exist, so it is omitted.
    @ViewBuilder
    func inlineNavigationTitle(_ title: String) -> some View {
        #if os(iOS)
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        #else
        self.navigationTitle(title)
        #endif
    }
}

#Preview {
    ContentView(project: SubtitleProject())
}
