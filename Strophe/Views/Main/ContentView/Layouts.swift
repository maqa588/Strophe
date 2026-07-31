//
//  ContentView+Layouts.swift
//  Strophe
//

import SwiftUI
import UniformTypeIdentifiers

extension ContentView {

    // MARK: - Wide Layout (iPad / macOS)
    //
    // The sidebar owns navigation and the custom tab bar; the detail column
    // remains the editor unless a settings route is pushed over it.

    var wideLayout: some View {
        NavigationSplitView {
            StropheSidebarContainer(project: project, selectedTab: $selectedTab, settingsPath: $settingsPath)
                .navigationSplitViewColumnWidth(300)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
        } detail: {
            NavigationStack(path: $settingsPath) {
                MainContentView(
                    project: project,
                    selectedTab: $selectedTab,
                    onSaveProject: saveProject,
                    onSaveProjectAs: saveProjectAs
                )
                .navigationDestination(for: SettingsRoute.self) { route in
                    SettingsDetailView(route: route, project: project)
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
    // The compact editor is full-screen; other destinations retain the tab bar.

    @ViewBuilder
    var compactLayout: some View {
        if selectedTab == .editor {
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
                                        NotificationCenter.default.post(
                                            name: .stropheStartSubtitleTranslation, object: nil)
                                    } label: {
                                        Label("subtitle_translation_assistant", systemImage: "character.bubble")
                                    }
                                    Button {
                                        NotificationCenter.default.post(
                                            name: .stropheStartBatchTranslation, object: nil)
                                    } label: {
                                        Label("batch_translate_subtitles", systemImage: "text.bubble")
                                    }
                                    Button {
                                        NotificationCenter.default.post(
                                            name: .stropheOpenKaraokeBatchRecognition, object: nil)
                                    } label: {
                                        Label("karaoke_batch_recognition", systemImage: "music.note.list")
                                    }
                                    Button {
                                        NotificationCenter.default.post(
                                            name: .stropheConvertSelectedToPinyin, object: nil)
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
                                Divider()
                                Button {
                                    NotificationCenter.default.post(name: .stropheOpenBilingualEditor, object: nil)
                                } label: {
                                    Label("bilingual_comparison_editor", systemImage: "rectangle.split.2x1")
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
                        SettingsDetailView(route: route, project: project)
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

    func showCurrentMediaInfoPage() {
        selectedTab = .settings
        DispatchQueue.main.async {
            settingsPath = [.currentMediaInfo]
        }
    }
}
