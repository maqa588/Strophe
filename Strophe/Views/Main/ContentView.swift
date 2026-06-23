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
    @Environment(\.horizontalSizeClass) var sizeClass

    @State private var selectedTab: StropheTab = .editor
    @State private var settingsPath: [SettingsRoute] = []

    @State private var isShowingSaveStrophe = false
    @State private var saveStropheDefaultName = "project"
    @State private var isShowingOpenProject = false
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
        #if os(iOS)
        if #available(iOS 26.0, *) { return true }
        #elseif os(macOS)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    var body: some View {
        Group {
            if sizeClass == .compact {
                compactLayout       // iPhone
            } else {
                wideLayout          // iPad / macOS
            }
        }
        .tint(Color.stropheAccent)
        .overlay {
            if project.isLoadingProject {
                projectLoadingOverlay
            }
        }
        .overlay {
            if isShowingRestoreTimeAlert {
                restoreTimeOverlay
            }
        }
        .fileImporter(
            isPresented: $isShowingOpenProject,
            allowedContentTypes: [.stropheProject],
            allowsMultipleSelection: false
        ) { handleOpenProject($0) }
        .fileExporter(
            isPresented: $isShowingSaveStrophe,
            document: project.stropheDocument,
            contentType: .stropheProject,
            defaultFilename: saveStropheDefaultName
        ) { result in
            if case .success(let url) = result {
                Task {
                    try? await project.saveStrophe(to: url)
                    project.startAutoSave()
                    #if os(macOS)
                    if isQuittingAfterSave {
                        project.markClean()
                        isQuittingAfterSave = false
                        NSApplication.shared.reply(toApplicationShouldTerminate: true)
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
            }
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
        #if os(macOS)
        .alert(
            String.localizedStringWithFormat(
                String(localized: "是否保存“%@”工程？"),
                project.documentDisplayName
            ),
            isPresented: $isShowingSaveOnQuitAlert
        ) {
            Button(String(localized: "保存")) {
                if let url = project.projectURL {
                    Task {
                        try? await project.saveStrophe(to: url)
                        project.markClean()
                        NSApplication.shared.reply(toApplicationShouldTerminate: true)
                    }
                } else {
                    isQuittingAfterSave = true
                    let base = project.documentDisplayName
                    saveStropheDefaultName = base.isEmpty ? "project" : base
                    isShowingSaveStrophe = true
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
        .onChange(of: project.loadedPlayheadTime) { newValue in
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
        .onReceive(NotificationCenter.default.publisher(for: .stropheOpenProjectWithURL)) { notification in
            if let url = notification.object as? URL {
                handleOpenProject(.success([url]))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheSaveProject)) { _ in
            if let url = project.projectURL {
                Task {
                    try? await project.saveStrophe(to: url)
                }
            } else {
                let base = project.documentDisplayName
                saveStropheDefaultName = base.isEmpty ? "project" : base
                isShowingSaveStrophe = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheSaveProjectAs)) { _ in
            let base = project.documentDisplayName
            saveStropheDefaultName = base.isEmpty ? "project" : base
            isShowingSaveStrophe = true
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .stropheShowSaveOnQuitAlert)) { _ in
            isShowingSaveOnQuitAlert = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheShowAbout)) { _ in
            selectedTab = .settings
            DispatchQueue.main.async {
                settingsPath = [.version]
            }
        }
        #endif
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
                .ignoresSafeArea(.container, edges: .top)
        } detail: {
            // ── 右列：始终为编辑器（设置详情通过 settingsPath 覆盖在它上面） ──
            NavigationStack(path: $settingsPath) {
                MainContentView(project: project, selectedTab: $selectedTab)
                    .navigationDestination(for: SettingsRoute.self) { route in
                        SettingsDetailView(route: route)
                    }
            }
        }
        .background(Color.stropheBackground)
        .onChange(of: selectedTab) { _ in
            settingsPath.removeAll()
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
            NavigationStack {
                MainContentView(project: project, selectedTab: $selectedTab)
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
                                #if !STROPHE_LITE
                                Button {
                                    NotificationCenter.default.post(name: .stropheStartSpeechRecognition, object: nil)
                                } label: {
                                    Label("语音识别", systemImage: "waveform.and.mic")
                                }
                                #endif
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
                StylePlaceholderView()
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

    private func handleOpenProject(_ result: Result<[URL], Error>) {
        DispatchQueue.main.async {
            guard case .success(let urls) = result, let url = urls.first else { return }
            if !project.items.isEmpty {
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
