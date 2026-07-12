//
//  ContentView+Layouts.swift
//  Strophe
//

import SwiftUI
import UniformTypeIdentifiers

extension ContentView {

    // MARK: - Wide Layout (iPad / macOS)
    //
    // 左列：当前 tab 的侧边栏内容（ScriptListView or Settings）+ 底部自绘 TabBar
    // 右列：始终显示 MainContentView（视频 + 波形）
    // 不使用 NavigationSplitView：避免两个 sidebar toggle 按钮冲突

    var wideLayout: some View {
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
    var compactLayout: some View {
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
    var compactTabContent: some View {
        switch selectedTab {
        case .scriptList:
            NavigationStack {
                ScriptListView(project: project)
                    .inlineNavigationTitle(String(localized: "script"))
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button {
                                    NotificationCenter.default.post(name: .strophePasteScript, object: nil)
                                } label: {
                                    Label("paste_script", systemImage: "doc.on.clipboard")
                                }
                                Button {
                                    NotificationCenter.default.post(name: .stropheImportScriptFile, object: nil)
                                } label: {
                                    Label("import_subtitle_file", systemImage: "square.and.arrow.down")
                                }
                                Button {
                                    NotificationCenter.default.post(name: .stropheStartSpeechRecognition, object: nil)
                                } label: {
                                    Label("speech_recognition_2", systemImage: "waveform.and.mic")
                                }
                                Divider()
                                Menu {
                                    Button {
                                        NotificationCenter.default.post(name: .stropheStartSubtitleTranslation, object: nil)
                                    } label: {
                                        Label("subtitle_translation_assistant", systemImage: "character.bubble")
                                    }
                                    Button {
                                        NotificationCenter.default.post(name: .stropheStartBatchTranslation, object: nil)
                                    } label: {
                                        Label("batch_translate_subtitles", systemImage: "text.bubble")
                                    }
                                    Button {
                                        NotificationCenter.default.post(name: .stropheConvertSelectedToPinyin, object: nil)
                                    } label: {
                                        Label("chinese_to_pinyin", systemImage: "character.phonetic")
                                    }
                                    Button {
                                        NotificationCenter.default.post(name: .stropheOpenAutoLineWrap, object: nil)
                                    } label: {
                                        Label("auto_line_wrap", systemImage: "return")
                                    }
                                } label: {
                                    Label("language_processing", systemImage: "globe")
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
                    .inlineNavigationTitle(String(localized: "style"))
            }
        case .subGroup:
            NavigationStack {
                SubGroupPlaceholderView(project: project)
                    .inlineNavigationTitle(String(localized: "group"))
            }
        case .settings:
            NavigationStack(path: $settingsPath) {
                SettingsPlaceholderView(settingsPath: $settingsPath)
                    .inlineNavigationTitle(String(localized: "settings"))
                    .navigationDestination(for: SettingsRoute.self) { route in
                        SettingsDetailView(route: route)
                    }
            }
        }
    }

    func showAboutPage() {
        selectedTab = .settings
        DispatchQueue.main.async {
            settingsPath = [.version]
        }
    }
}
