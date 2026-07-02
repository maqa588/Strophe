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
    
    var body: some Commands {
        #if os(macOS)
        CommandGroup(replacing: .undoRedo) {
            EmptyView()
        }
        #endif

        timelineCommandMenu

        CommandGroup(replacing: .newItem) {
            Button(String(localized: "Open")) {
                NotificationCenter.default.post(name: .stropheImportMedia, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)
            
            Button(String(localized: "Open Strophe Project...")) {
                NotificationCenter.default.post(name: .stropheOpenProject, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        
        CommandGroup(replacing: .saveItem) {
            Button(String(localized: "Save")) {
                NotificationCenter.default.post(name: .stropheSaveProject, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(project.videoURL == nil && project.items.isEmpty)
            
            Button(String(localized: "Save As...")) {
                NotificationCenter.default.post(name: .stropheSaveProjectAs, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(project.videoURL == nil && project.items.isEmpty)
        }
        
        CommandGroup(replacing: .appInfo) {
            Button("\(String(localized: "About")) \(AppIdentity.displayName)") {
                NotificationCenter.default.post(name: .stropheShowAbout, object: nil)
            }
        }
    }

    private var timelineCommandMenu: some Commands {
        CommandMenu(String(localized: "时间轴")) {
            Button(String(localized: "Undo")) {
                project.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(project.isEditingText || !project.canUndo)

            Button(String(localized: "Redo")) {
                project.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(project.isEditingText || !project.canRedo)

            Divider()

            Button(String(localized: "剪切字幕块")) {
                project.cutSelectedSubtitleBlocks()
            }
            .keyboardShortcut("x", modifiers: .command)
            .disabled(!project.canCutSelectedSubtitleBlocks)

            Button(String(localized: "复制字幕块")) {
                project.copySelectedSubtitleBlocks()
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(!project.canCopySelectedSubtitleBlocks)

            Button(String(localized: "粘贴字幕块")) {
                project.pasteSubtitleBlocksIntoActiveGroup()
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!project.canPasteSubtitleBlocks)

            Divider()

            Button(String(localized: "字幕块左对齐")) {
                project.seekToSubtitleBoundary(.left)
            }
            .keyboardShortcut("[", modifiers: [])
            .disabled(project.isEditingText || project.items.isEmpty)

            Button(String(localized: "字幕块右对齐")) {
                project.seekToSubtitleBoundary(.right)
            }
            .keyboardShortcut("]", modifiers: [])
            .disabled(project.isEditingText || project.items.isEmpty)
        }
    }
}

// MARK: - Main Custom Toolbar
struct StropheMainToolbar: ToolbarContent {
    @ObservedObject var project: SubtitleProject
    var horizontalSizeClass: UserInterfaceSizeClass?
    var onImportMedia: () -> Void
    var onExportSoftSubtitles: (SubtitleFormat) -> Void
    var onExportHardSubtitles: () -> Void
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

                Button(action: onImportMedia) {
                    Image(systemName: "folder")
                }
                .help(String(localized: "导入媒体文件"))
            } else {
                Button(action: onImportMedia) {
                    Image(systemName: "folder")
                }
                .help(String(localized: "导入媒体文件"))
            }
            #else
            Button(action: onImportMedia) {
                Label("导入媒体", systemImage: "folder")
            }
            .help(String(localized: "导入视频或音频文件到当前项目"))
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
            Button(action: {
                NotificationCenter.default.post(name: .stropheSaveProject, object: nil)
            }) {
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
                    NotificationCenter.default.post(name: .stropheSaveProjectAs, object: nil)
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
                    #if !STROPHE_LITE
                    Button {
                        NotificationCenter.default.post(name: .stropheStartSpeechRecognition, object: nil)
                    } label: {
                        Label("语音识别", systemImage: "waveform.and.mic")
                    }
                    #endif
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
