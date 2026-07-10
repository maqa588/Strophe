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

    @State private var selectedTab: StropheTab = .editor
    @State private var settingsPath: [SettingsRoute] = []

    @State private var isShowingSaveStrophe = false
    @State private var saveStropheDefaultName = "project"
    @State private var cachedProjectURLPendingPromotion: URL? = nil
    @State private var isShowingOpenProject = false
    @State private var isShowingReplaceMedia = false
    @State private var isShowingSubtitleImporter = false
    @State private var isShowingNewProjectAlert = false
    @State private var fileActionError: String? = nil
    @State private var isShowingOverwriteAlert = false
    @State private var pendingStropheURL: URL? = nil
    @State private var isShowingRestoreTimeAlert = false
    @State private var pendingRestoreTime: Double = 0
    #if os(macOS)
    @State private var isShowingSaveOnQuitAlert = false
    @State private var isQuittingAfterSave = false
    @State private var keyboardMonitor: Any?
    #endif

    private var usesLiquidGlassNavigation: Bool {
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
            String(localized: "是否新建工程？"),
            isPresented: $isShowingNewProjectAlert
        ) {
            Button(String(localized: "新建工程"), role: .destructive) {
                createNewProject()
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "新建工程会清空当前视频、字幕和未保存的修改。"))
        }
        .alert(
            String(localized: "是否覆盖现有字幕？"),
            isPresented: $isShowingOverwriteAlert
        ) {
            Button(String(localized: "覆盖"), role: .destructive) {
                if let url = pendingStropheURL {
                    Task {
                        await openProject(url)
                    }
                }
                pendingStropheURL = nil
            }
            Button(String(localized: "取消"), role: .cancel) {
                pendingStropheURL = nil
            }
        } message: {
            Text(String(localized: "导入该工程文件将覆盖你当前正在编辑的字幕。"))
        }
        .alert(
            String(localized: "无法完成操作"),
            isPresented: Binding(
                get: { fileActionError != nil },
                set: { if !$0 { fileActionError = nil } }
            )
        ) {
            Button(String(localized: "好"), role: .cancel) {
                fileActionError = nil
            }
        } message: {
            Text(fileActionError ?? "")
        }
        #if os(macOS)
        .alert(
            String.localizedStringWithFormat(
                String(localized: "是否保存“%@”工程？"),
                project.documentDisplayName
            ),
            isPresented: $isShowingSaveOnQuitAlert
        ) {
            Button(String(localized: "保存")) {
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
            Button(String(localized: "不保存"), role: .destructive) {
                project.markClean()
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
            Button(String(localized: "取消"), role: .cancel) {
                NSApplication.shared.reply(toApplicationShouldTerminate: false)
            }
        } message: {
            Text(String(localized: "如果未保存，编辑的内容将会丢失。"))
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
    }

    private func presentSaveStropheExporter() {
        let base = project.documentDisplayName
        saveStropheDefaultName = base.isEmpty ? "project" : base
        if let url = project.projectURL, SubtitleProject.isManagedProjectCacheURL(url) {
            cachedProjectURLPendingPromotion = url
        } else {
            cachedProjectURLPendingPromotion = nil
        }
        isShowingSaveStrophe = true
    }

    private func saveProject() {
        if let url = project.projectURL,
           !SubtitleProject.isManagedProjectCacheURL(url) {
            Task {
                do {
                    try await project.saveStrophe(to: url)
                    WelcomeRecentProjectsStore.remember(url)
                } catch {
                    print("⚠️ Failed to save Strophe project: \(error.localizedDescription)")
                }
            }
        } else {
            presentSaveStropheExporter()
        }
    }

    private func saveProjectAs() {
        presentSaveStropheExporter()
    }

    private var hasCurrentProjectContent: Bool {
        project.videoURL != nil || project.projectURL != nil || !project.items.isEmpty || project.isDirty
    }

    private func requestNewProject() {
        if hasCurrentProjectContent {
            isShowingNewProjectAlert = true
        } else {
            createNewProject()
        }
    }

    private func createNewProject() {
        project.createNewProject()
        selectedTab = .editor
        settingsPath.removeAll()
    }

    // MARK: - Wide Layout (iPad / macOS)
    //
    // 左列：当前 tab 的侧边栏内容（ScriptListView or Settings）+ 底部自绘 TabBar
    // 右列：始终显示 MainContentView（视频 + 波形）
    // 不使用 NavigationSplitView：避免两个 sidebar toggle 按钮冲突

    private var wideLayout: some View {
        NavigationSplitView {
            // ── 左列：侧边栏容器 ──
            StropheSidebarContainer(project: project, selectedTab: $selectedTab, settingsPath: $settingsPath)
                .navigationSplitViewColumnWidth(300)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
        } detail: {
            // ── 右列：始终为编辑器（设置详情通过 settingsPath 覆盖在它上面） ──
            NavigationStack(path: $settingsPath) {
                MainContentView(
                    project: project,
                    selectedTab: $selectedTab,
                    onSaveProject: saveProject,
                    onSaveProjectAs: saveProjectAs
                )
                    .navigationDestination(for: SettingsRoute.self) { route in
                        SettingsDetailView(route: route)
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(Color.stropheBackground)
        .stropheOnChange(of: selectedTab) { newValue in
            if newValue != .settings {
                settingsPath.removeAll()
            }
        }
    }

    // MARK: - Compact Layout (iPhone)
    //
    // 编辑器 tab：全屏 MainContentView，TabBar 不显示，左上有返回按钮
    // 其他 tab：当前 tab 内容 + 底部自绘 TabBar（文稿 | 编辑器 | 设置）

    @ViewBuilder
    private var compactLayout: some View {
        if selectedTab == .editor {
            // 编辑器全屏，不显示 TabBar
            if embedsCompactEditorInNavigationStack {
                NavigationStack {
                    MainContentView(
                        project: project,
                        selectedTab: $selectedTab,
                        onSaveProject: saveProject,
                        onSaveProjectAs: saveProjectAs
                    )
                }
            } else {
                MainContentView(
                    project: project,
                    selectedTab: $selectedTab,
                    onSaveProject: saveProject,
                    onSaveProjectAs: saveProjectAs
                )
            }
        } else if usesLiquidGlassNavigation {
            ZStack(alignment: .bottom) {
                compactTabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .bottom)

                if selectedTab != .settings || settingsPath.isEmpty {
                    StropheTabBar(selectedTab: $selectedTab, tabs: StropheTab.compactTabs)
                }
            }
            .background(Color.stropheBackground)
            .ignoresSafeArea(.keyboard, edges: .bottom)
        } else {
            VStack(spacing: 0) {
                compactTabContent
                    .frame(maxHeight: .infinity)

                if selectedTab != .settings || settingsPath.isEmpty {
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color.stropheBorder)

                    StropheTabBar(selectedTab: $selectedTab, tabs: StropheTab.compactTabs)
                        .padding(.top, 12)
                }
            }
            .background(Color.stropheBackground)
        }
    }

    @ViewBuilder
    private var compactTabContent: some View {
        switch selectedTab {
        case .scriptList:
            NavigationStack {
                ScriptListView(project: project)
                    .inlineNavigationTitle(String(localized: "文稿"))
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button {
                                    NotificationCenter.default.post(name: .strophePasteScript, object: nil)
                                } label: {
                                    Label("粘贴文稿", systemImage: "doc.on.clipboard")
                                }
                                Button {
                                    NotificationCenter.default.post(name: .stropheImportScriptFile, object: nil)
                                } label: {
                                    Label("导入字幕文件", systemImage: "square.and.arrow.down")
                                }
                                Button {
                                    NotificationCenter.default.post(name: .stropheStartSpeechRecognition, object: nil)
                                } label: {
                                    Label("语音识别", systemImage: "waveform.and.mic")
                                }
                                Divider()
                                Menu {
                                    Button {
                                        NotificationCenter.default.post(name: .stropheStartSubtitleTranslation, object: nil)
                                    } label: {
                                        Label("字幕翻译助手", systemImage: "character.bubble")
                                    }
                                    Button {
                                        NotificationCenter.default.post(name: .stropheStartBatchTranslation, object: nil)
                                    } label: {
                                        Label("批量翻译字幕", systemImage: "text.bubble")
                                    }
                                    Button {
                                        NotificationCenter.default.post(name: .stropheConvertSelectedToPinyin, object: nil)
                                    } label: {
                                        Label("汉字转拼音", systemImage: "character.phonetic")
                                    }
                                    Button {
                                        NotificationCenter.default.post(name: .stropheOpenAutoLineWrap, object: nil)
                                    } label: {
                                        Label("自动换行", systemImage: "return")
                                    }
                                } label: {
                                    Label("语言处理", systemImage: "globe")
                                }
                            } label: {
                                Image(systemName: "plus")
                            }
                        }
                    }
            }
        case .editor:
            EmptyView()
        case .styleManager:
            NavigationStack {
                StylePlaceholderView(project: project)
                    .inlineNavigationTitle(String(localized: "样式"))
            }
        case .subGroup:
            NavigationStack {
                SubGroupPlaceholderView(project: project)
                    .inlineNavigationTitle(String(localized: "组别"))
            }
        case .settings:
            NavigationStack(path: $settingsPath) {
                SettingsPlaceholderView(settingsPath: $settingsPath)
                    .inlineNavigationTitle(String(localized: "设置"))
                    .navigationDestination(for: SettingsRoute.self) { route in
                        SettingsDetailView(route: route)
                    }
            }
        }
    }

    private func showAboutPage() {
        selectedTab = .settings
        DispatchQueue.main.async {
            settingsPath = [.version]
        }
    }

    // MARK: - Keyboard Monitor (macOS)

    private func setupKeyboardMonitor() {
        #if os(macOS)
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            if let keyWindow = NSApp.keyWindow,
               let responder = keyWindow.firstResponder {
                let className = String(describing: type(of: responder))
                if responder is NSText || className.contains("Text") || className.contains("Field") || className.contains("Editor") {
                    return event
                }
            }

            if project.isEditingText { return event }

            let isKeyDown = event.type == .keyDown
            let isKeyUp   = event.type == .keyUp

            if let chars = event.charactersIgnoringModifiers?.lowercased(),
               chars == "j" || chars == "k" {
                if project.editingMode == .creation {
                    if isKeyDown, !event.isARepeat { project.handleSlapKeyDown(key: chars) }
                    else if isKeyUp { project.handleSlapKeyUp(key: chars) }
                    return nil
                }
            }

            if isKeyDown {
                let mod = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if mod == .command, event.charactersIgnoringModifiers == "z" {
                    project.undo(); return nil
                }
                if mod == [.command, .shift], event.charactersIgnoringModifiers == "Z" {
                    project.redo(); return nil
                }
                if mod == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
                    guard project.canCopySelectedSubtitleBlocks else { return event }
                    project.copySelectedSubtitleBlocks(); return nil
                }
                if mod == .command, event.charactersIgnoringModifiers?.lowercased() == "x" {
                    guard project.canCutSelectedSubtitleBlocks else { return event }
                    project.cutSelectedSubtitleBlocks(); return nil
                }
                if mod == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
                    guard project.canPasteSubtitleBlocks else { return event }
                    project.pasteSubtitleBlocksIntoActiveGroup(); return nil
                }
                if mod.isEmpty {
                    switch event.keyCode {
                    case 33:
                        project.seekToSubtitleBoundary(.left); return nil
                    case 30:
                        project.seekToSubtitleBoundary(.right); return nil
                    case 123:
                        project.seekByFrames(-1); return nil
                    case 124:
                        project.seekByFrames(1); return nil
                    default:
                        break
                    }
                }
                if mod == .option,
                   let rawKey = event.charactersIgnoringModifiers,
                   let number = Int(rawKey),
                   (1...9).contains(number),
                   let group = StyleAndGroupStore.shared.shortcutGroup(number: number) {
                    if project.selectedIDs.isEmpty {
                        StyleAndGroupStore.shared.setActiveGroup(group.id)
                    } else {
                        project.assignSelectedSubtitles(toGroup: group.id)
                    }
                    return nil
                }
                switch event.charactersIgnoringModifiers {
                case " ":
                    project.togglePlayback(); return nil
                case "\u{7F}", "\u{08}":
                    if !project.selectedIDs.isEmpty {
                        project.deleteSubtitles(ids: project.selectedIDs)
                        project.selectedIDs.removeAll()
                        return nil
                    }
                    return event
                default:
                    return event
                }
            }
            return event
        }
        #endif
    }

    #if os(macOS)
    private func removeKeyboardMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }
    #endif



    // MARK: - File Handlers

    private func handleReplaceMedia(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            project.replaceMedia(with: url)
            selectedTab = .editor
            settingsPath.removeAll()
        case .failure(let error):
            fileActionError = error.localizedDescription
        }
    }

    private func handleSubtitleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let rawText = try SubtitleEngine.loadRawText(from: url)
                project.importScript(rawText)
                selectedTab = .editor
                settingsPath.removeAll()
            } catch {
                fileActionError = error.localizedDescription
            }
        case .failure(let error):
            fileActionError = error.localizedDescription
        }
    }

    private func handleOpenProject(_ result: Result<[URL], Error>) {
        DispatchQueue.main.async {
            guard case .success(let urls) = result, let url = urls.first else { return }
            if hasCurrentProjectContent {
                pendingStropheURL = url
                isShowingOverwriteAlert = true
            } else {
                Task {
                    await openProject(url)
                }
            }
        }
    }

    private var projectLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "正在打开项目"))
                    .font(.caption.weight(.semibold))
                Text(String(localized: "正在读取字幕、重建时间轴索引并准备波形"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.stropheBorder.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private var restoreTimeOverlay: some View {
        ZStack {
            Color.black.opacity(0.24)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text(String(localized: "是否回到上次编辑位置？"))
                        .font(.headline)
                        .foregroundStyle(Color.stropheText)

                    Text(String(localized: "该工程文件保存了上一次的时间轴位置，是否要跳转到该位置？"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 16) {
                    Button(String(localized: "不恢复")) {
                        dismissRestoreTimePrompt()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(String(localized: "恢复位置")) {
                        restorePendingTimelinePosition()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
            .frame(width: 360, height: 160)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.stropheBorder.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        }
    }

    private func dismissRestoreTimePrompt() {
        isShowingRestoreTimeAlert = false
    }

    private func restorePendingTimelinePosition() {
        project.seek(to: pendingRestoreTime)
        isShowingRestoreTimeAlert = false
    }

    @MainActor
    private func openProject(_ url: URL) async {
        project.isLoadingProject = true
        await Task.yield()
        defer { project.isLoadingProject = false }
        do {
            try await project.importStropheProject(from: url)
            WelcomeRecentProjectsStore.remember(url)
        } catch {
            print("Failed to open project: \(error.localizedDescription)")
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

private extension View {
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
