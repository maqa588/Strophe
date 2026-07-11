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
            Button(String(localized: "new_project")) {
                NotificationCenter.default.post(name: .stropheNewProject, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button(String(localized: "replace_video_ellipsis")) {
                NotificationCenter.default.post(name: .stropheReplaceMedia, object: nil)
            }
            .disabled(project.videoURL == nil)

            Button(String(localized: "import_subtitle_file_ellipsis")) {
                NotificationCenter.default.post(name: .stropheImportScriptFile, object: nil)
            }

            Button(String(localized: "open_strophe_project_ellipsis")) {
                NotificationCenter.default.post(name: .stropheOpenProject, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        
        CommandGroup(replacing: .saveItem) {
            Button(String(localized: "btn_save")) {
                NotificationCenter.default.post(name: .stropheSaveProject, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!canSaveProject)
            
            Button(String(localized: "save_as")) {
                NotificationCenter.default.post(name: .stropheSaveProjectAs, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!canSaveProject)
        }
        
        CommandGroup(replacing: .appInfo) {
            Button("\(String(localized: "menu_about")) \(AppIdentity.displayName)") {
                NotificationCenter.default.post(name: .stropheShowAbout, object: nil)
            }
        }
    }

    @ViewBuilder
    private var timelineCommandItems: some View {
        Button("menu_undo") {
            project.undo()
        }
        .timelineShortcut("z", modifiers: .command)
        .disabled(project.isEditingText || !project.canUndo)

        Button("menu_redo") {
            project.redo()
        }
        .timelineShortcut("z", modifiers: [.command, .shift])
        .disabled(project.isEditingText || !project.canRedo)

        Divider()

        Button("cut_subtitle_block") {
            project.cutSelectedSubtitleBlocks()
        }
        .timelineShortcut("x", modifiers: .command)
        .disabled(!project.canCutSelectedSubtitleBlocks)

        Button("copy_subtitle_block") {
            project.copySelectedSubtitleBlocks()
        }
        .timelineShortcut("c", modifiers: .command)
        .disabled(!project.canCopySelectedSubtitleBlocks)

        Button("paste_subtitle_block") {
            project.pasteSubtitleBlocksIntoActiveGroup()
        }
        .timelineShortcut("v", modifiers: .command)
        .disabled(!project.canPasteSubtitleBlocks)

        Divider()

        Button("align_subtitle_block_left") {
            project.seekToSubtitleBoundary(.left)
        }
        .timelineShortcut("[", modifiers: [])
        .disabled(project.isEditingText || project.items.isEmpty)

        Button("align_subtitle_block_right") {
            project.seekToSubtitleBoundary(.right)
        }
        .timelineShortcut("]", modifiers: [])
        .disabled(project.isEditingText || project.items.isEmpty)
    }

    private var timelineCommandMenu: some Commands {
        CommandMenu("timeline") {
            timelineCommandItems
        }
    }

    @ViewBuilder
    private var languageProcessingItems: some View {
        Button("open_subtitle_translator_ellipsis") {
            NotificationCenter.default.post(name: .stropheStartSubtitleTranslation, object: nil)
        }

        Button("batch_translate_subtitles_ellipsis") {
            NotificationCenter.default.post(name: .stropheStartBatchTranslation, object: nil)
        }

        Divider()

        Button("chinese_to_pinyin_ellipsis") {
            NotificationCenter.default.post(name: .stropheConvertSelectedToPinyin, object: nil)
        }

        Button("auto_line_wrap_ellipsis") {
            NotificationCenter.default.post(name: .stropheOpenAutoLineWrap, object: nil)
        }
    }

    private var languageProcessingCommandMenu: some Commands {
        CommandMenu("language_processing") {
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
                .help(String(localized: "return_to_document_list"))

            }

            Menu {
                projectFileMenuItems
            } label: {
                Image(systemName: "folder")
            }
            .help(String(localized: "project_file_operations"))
            #else
            Menu {
                projectFileMenuItems
            } label: {
                Label("project", systemImage: "folder")
            }
            .help(String(localized: "project_file_operations"))
            #endif
        }

        #if os(iOS)
        ToolbarItem(placement: .principal) {
            Text(project.documentDisplayName.isEmpty ? String(localized: "app_name") : project.documentDisplayName)
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
                Label("save", systemImage: "square.and.arrow.down")
                #else
                Image(systemName: "square.and.arrow.down")
                #endif
            }
            .help(String(localized: "save_current_project_file"))

            // Export Menu
            Menu {
                Menu("format_soft_subtitles") {
                    Button("format_srt") {
                        onExportSoftSubtitles(.srt)
                    }
                    Button("format_ass") {
                        onExportSoftSubtitles(.ass)
                    }
                    Button("format_lrc") {
                        onExportSoftSubtitles(.lrc)
                    }
                    Button("format_vtt") {
                        onExportSoftSubtitles(.vtt)
                    }
                }

                Divider()

                Button("strophe_project_strophe") {
                    onSaveProjectAs()
                }

                Divider()

                Button("hard_subtitled_video_ellipsis") {
                    onExportHardSubtitles()
                }
                Button("video_stream_coming_soon") {}.disabled(true)
                Button("audio_stream_coming_soon") {}.disabled(true)
            } label: {
                #if os(macOS)
                Label("export", systemImage: "square.and.arrow.up")
                #else
                Image(systemName: "square.and.arrow.up")
                #endif
            }
            .help(String(localized: "export_subtitles_or_share_project"))
        }
    }

    @ViewBuilder
    private var projectFileMenuItems: some View {
        Button {
            NotificationCenter.default.post(name: .stropheNewProject, object: nil)
        } label: {
            Label("new_project", systemImage: "plus.square")
        }

        Button {
            NotificationCenter.default.post(name: .stropheReplaceMedia, object: nil)
        } label: {
            Label("replace_video_ellipsis", systemImage: "rectangle.2.swap")
        }
        .disabled(project.videoURL == nil)

        Button {
            NotificationCenter.default.post(name: .stropheImportScriptFile, object: nil)
        } label: {
            Label("import_subtitle_file_ellipsis", systemImage: "captions.bubble")
        }

        Button {
            NotificationCenter.default.post(name: .stropheOpenProject, object: nil)
        } label: {
            Label("open_strophe_project_ellipsis", systemImage: "folder")
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
                        .font(.system(size: 14, weight: .medium))
                }
                #if os(macOS)
                .help(String(localized: "paste_or_import_script"))
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
