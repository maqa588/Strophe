//
//  ContentView.swift
//  Strophe
//
//  Adaptive navigation layout:
//
//  iPad and macOS:
//    ┌──────────────┬────────────────────────┐
//    │ NavigationStack            │ NavigationStack        │
//    │ (ScriptListView /          │ MainContentView        │
//    │  SettingsPlaceholder)      │ (video + timeline)      │
//    │                            │                        │
//    │ [custom tab bar]           │                        │
//    └──────────────┴────────────────────────┘
//
//  iPhone outside the editor: a NavigationStack above the custom tab bar.
//
//  iPhone editor: MainContentView occupies the full stack and supplies its own back action.
//

import SwiftUI
import UniformTypeIdentifiers

private enum WorkspaceSheet: String, Identifiable {
    case subtitleEditingTools
    case bilingualEditor
    case projectMarkers

    var id: String { rawValue }

    var isTextEditingWorkspace: Bool {
        self == .subtitleEditingTools || self == .bilingualEditor
    }
}

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
    @State private var presentedWorkspaceSheet: WorkspaceSheet?
    #if os(macOS)
        @State private var isShowingSaveOnQuitAlert = false
        @State private var isQuittingAfterSave = false
        @State var keyboardMonitor: Any?
    #endif
    @State var showSavedToast = false
    @State private var successToastMessage = String(localized: "project_saved_success")
    @State private var successToastGeneration = 0

    func triggerSaveToast() {
        triggerSuccessToast(String(localized: "project_saved_success"))
    }

    private func triggerSuccessToast(_ message: String) {
        successToastGeneration += 1
        let generation = successToastGeneration
        successToastMessage = message
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showSavedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard generation == successToastGeneration else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                showSavedToast = false
            }
        }
    }

    var usesLiquidGlassNavigation: Bool {
        if #available(anyAppleOS 26.0, *) { true } else { false }
    }

    @ViewBuilder
    private var editorLayout: some View {
        Group {
            if sizeClass == .compact {
                compactLayout  // iPhone
            } else {
                wideLayout  // iPad / macOS
            }
        }
        #if os(iOS)
            .ignoresSafeArea(.keyboard, edges: .bottom)
        #endif
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
        .overlay(alignment: .top) {
            if showSavedToast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(successToastMessage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.stropheText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color.stropheSecondaryBackground)
                        .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 4)
                )
                .overlay(
                    Capsule().stroke(Color.green.opacity(0.4), lineWidth: 1)
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 12)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheShowSuccessToast)) { notification in
            guard let message = notification.object as? String, !message.isEmpty else { return }
            triggerSuccessToast(message)
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
                            await MainActor.run {
                                triggerSaveToast()
                            }
                            if let cachedURL = cachedProjectURLPendingPromotion,
                                cachedURL.standardizedFileURL != url.standardizedFileURL
                            {
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
                            !SubtitleProject.isManagedProjectCacheURL(url)
                        {
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
            .sheet(item: $presentedWorkspaceSheet) { sheet in
                switch sheet {
                case .subtitleEditingTools:
                    SubtitleEditingToolsView(project: project)
                case .bilingualEditor:
                    BilingualComparisonEditorView(project: project)
                case .projectMarkers:
                    ProjectMarkersView(project: project)
                }
            }
            .stropheOnChange(of: presentedWorkspaceSheet) { sheet in
                project.isEditingText = sheet?.isTextEditingWorkspace == true
            }
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
            .onReceive(NotificationCenter.default.publisher(for: .stropheShowCurrentMediaInfo)) { _ in
                showCurrentMediaInfoPage()
            }
            .onReceive(NotificationCenter.default.publisher(for: .stropheOpenEditingTools)) { _ in
                presentedWorkspaceSheet = .subtitleEditingTools
            }
            .onReceive(NotificationCenter.default.publisher(for: .stropheOpenBilingualEditor)) { _ in
                presentedWorkspaceSheet = .bilingualEditor
            }
            .onReceive(NotificationCenter.default.publisher(for: .stropheShowProjectMarkers)) { _ in
                presentedWorkspaceSheet = .projectMarkers
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
    static let togglePlayback = Notification.Name("com.swiftsub.togglePlayback")
    static let requestCurrentTime = Notification.Name("com.swiftsub.requestCurrentTime")
    static let seekDelta = Notification.Name("com.swiftsub.seekDelta")
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
