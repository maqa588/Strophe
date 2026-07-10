//
//  StropheNavBarCommands.swift
//  Strophe
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - macOS/iPadOS Commands
struct StropheNavBarCommands: Commands {
    @ObservedObject var project: SubtitleProject

    private var canSaveProject: Bool {
        project.projectURL != nil || project.videoURL != nil || !project.items.isEmpty || project.isDirty
    }
    
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            EmptyView()
        }

        timelineCommandMenu
        languageProcessingCommandMenu

        CommandGroup(replacing: .newItem) {
            Button(String(localized: "新建工程")) {
                NotificationCenter.default.post(name: .stropheNewProject, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button(String(localized: "替换视频…")) {
                NotificationCenter.default.post(name: .stropheReplaceMedia, object: nil)
            }
            .disabled(project.videoURL == nil)

            Button(String(localized: "导入字幕文件…")) {
                NotificationCenter.default.post(name: .stropheImportScriptFile, object: nil)
            }

            Button(String(localized: "打开 Strophe 工程…")) {
                NotificationCenter.default.post(name: .stropheOpenProject, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        
        CommandGroup(replacing: .saveItem) {
            Button(String(localized: "Save")) {
                NotificationCenter.default.post(name: .stropheSaveProject, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!canSaveProject)
            
            Button(String(localized: "Save As...")) {
                NotificationCenter.default.post(name: .stropheSaveProjectAs, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!canSaveProject)
        }
        
        CommandGroup(replacing: .appInfo) {
            Button("\(String(localized: "About")) \(AppIdentity.displayName)") {
                NotificationCenter.default.post(name: .stropheShowAbout, object: nil)
            }
        }
    }

    @ViewBuilder
    private var timelineCommandItems: some View {
        Button("Undo") {
            project.undo()
        }
        .timelineShortcut("z", modifiers: .command)
        .disabled(project.isEditingText || !project.canUndo)

        Button("Redo") {
            project.redo()
        }
        .timelineShortcut("z", modifiers: [.command, .shift])
        .disabled(project.isEditingText || !project.canRedo)

        Divider()

        Button("剪切字幕块") {
            project.cutSelectedSubtitleBlocks()
        }
        .timelineShortcut("x", modifiers: .command)
        .disabled(!project.canCutSelectedSubtitleBlocks)

        Button("复制字幕块") {
            project.copySelectedSubtitleBlocks()
        }
        .timelineShortcut("c", modifiers: .command)
        .disabled(!project.canCopySelectedSubtitleBlocks)

        Button("粘贴字幕块") {
            project.pasteSubtitleBlocksIntoActiveGroup()
        }
        .timelineShortcut("v", modifiers: .command)
        .disabled(!project.canPasteSubtitleBlocks)

        Divider()

        Button("字幕块左对齐") {
            project.seekToSubtitleBoundary(.left)
        }
        .timelineShortcut("[", modifiers: [])
        .disabled(project.isEditingText || project.items.isEmpty)

        Button("字幕块右对齐") {
            project.seekToSubtitleBoundary(.right)
        }
        .timelineShortcut("]", modifiers: [])
        .disabled(project.isEditingText || project.items.isEmpty)
    }

    private var timelineCommandMenu: some Commands {
        CommandMenu("时间轴") {
            timelineCommandItems
        }
    }

    @ViewBuilder
    private var languageProcessingItems: some View {
        Button("打开字幕翻译器…") {
            NotificationCenter.default.post(name: .stropheStartSubtitleTranslation, object: nil)
        }

        Button("批量翻译字幕…") {
            NotificationCenter.default.post(name: .stropheStartBatchTranslation, object: nil)
        }

        Divider()

        Button("汉字转拼音…") {
            NotificationCenter.default.post(name: .stropheConvertSelectedToPinyin, object: nil)
        }

        Button("自动换行…") {
            NotificationCenter.default.post(name: .stropheOpenAutoLineWrap, object: nil)
        }
    }

    private var languageProcessingCommandMenu: some Commands {
        CommandMenu("语言处理") {
            languageProcessingItems
        }
    }
}

// MARK: - Main Custom Toolbar
struct StropheMainToolbar: ToolbarContent {
    @ObservedObject var project: SubtitleProject
    var horizontalSizeClass: UserInterfaceSizeClass?
    var onExportSoftSubtitles: (SubtitleFormat) -> Void
    var onExportHardSubtitles: () -> Void
    var onSaveProject: () -> Void
    var onSaveProjectAs: () -> Void
    @Binding var selectedTab: StropheTab

    var body: some ToolbarContent {
        // Left side: back button (on compact iPhone) and import folder
        ToolbarItemGroup(placement: .navigation) {
            #if os(iOS)
            if horizontalSizeClass == .compact {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedTab = .scriptList
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                }
                .help(String(localized: "返回文稿列表"))

            }

            Menu {
                projectFileMenuItems
            } label: {
                Image(systemName: "folder")
            }
            .help(String(localized: "工程文件操作"))
            #else
            Menu {
                projectFileMenuItems
            } label: {
                Label("工程", systemImage: "folder")
            }
            .help(String(localized: "工程文件操作"))
            #endif
        }

        #if os(iOS)
        ToolbarItem(placement: .principal) {
            Text(project.documentDisplayName.isEmpty ? String(localized: "Strophe") : project.documentDisplayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(project.videoURL != nil ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        #endif

        // Right side items
        ToolbarItemGroup(placement: .primaryAction) {
            // Save Project Button
            Button(action: onSaveProject) {
                #if os(macOS)
                Label("保存", systemImage: "square.and.arrow.down")
                #else
                Image(systemName: "square.and.arrow.down")
                #endif
            }
            .help(String(localized: "保存当前工程文件"))

            // Export Menu
            Menu {
                Menu("Soft Subtitles") {
                    Button("SubRip (.srt)") {
                        onExportSoftSubtitles(.srt)
                    }
                    Button("Advanced SubStation Alpha (.ass)") {
                        onExportSoftSubtitles(.ass)
                    }
                    Button("Lyrics (.lrc)") {
                        onExportSoftSubtitles(.lrc)
                    }
                    Button("WebVTT (.vtt)") {
                        onExportSoftSubtitles(.vtt)
                    }
                }

                Divider()

                Button("Strophe Project (.strophe)") {
                    onSaveProjectAs()
                }

                Divider()

                Button("Hard Subtitled Video…") {
                    onExportHardSubtitles()
                }
                Button("Video Stream (Coming Soon)") {}.disabled(true)
                Button("Audio Stream (Coming Soon)") {}.disabled(true)
            } label: {
                #if os(macOS)
                Label("导出", systemImage: "square.and.arrow.up")
                #else
                Image(systemName: "square.and.arrow.up")
                #endif
            }
            .help(String(localized: "导出字幕或分享项目"))
        }
    }

    @ViewBuilder
    private var projectFileMenuItems: some View {
        Button {
            NotificationCenter.default.post(name: .stropheNewProject, object: nil)
        } label: {
            Label("新建工程", systemImage: "plus.square")
        }

        Button {
            NotificationCenter.default.post(name: .stropheReplaceMedia, object: nil)
        } label: {
            Label("替换视频…", systemImage: "rectangle.2.swap")
        }
        .disabled(project.videoURL == nil)

        Button {
            NotificationCenter.default.post(name: .stropheImportScriptFile, object: nil)
        } label: {
            Label("导入字幕文件…", systemImage: "captions.bubble")
        }

        Button {
            NotificationCenter.default.post(name: .stropheOpenProject, object: nil)
        } label: {
            Label("打开 Strophe 工程…", systemImage: "folder")
        }
    }
}

// MARK: - Sidebar Custom Toolbar
struct StropheSidebarToolbar: ToolbarContent {
    var selectedTab: StropheTab

    var body: some ToolbarContent {
        if selectedTab == .editor || selectedTab == .scriptList {
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
                        .font(.system(size: 14, weight: .medium))
                }
                #if os(macOS)
                .help(String(localized: "粘贴或导入文稿"))
                #endif
            }
        }
    }
}

// MARK: - iPadOS 26+ Menu Bar Configurations
#if os(iOS)

// Empty - removed StropheMenuBarConfigurator
#endif

// MARK: - View Helper Extensions
private extension View {
    @ViewBuilder
    func timelineShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        #if os(macOS)
        self.keyboardShortcut(key, modifiers: modifiers)
        #else
        self
        #endif
    }
}
