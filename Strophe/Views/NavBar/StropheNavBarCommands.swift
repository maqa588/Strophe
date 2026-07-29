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
            Button(String(localized: "menu_undo")) {
                performUndo()
            }
            .keyboardShortcut("z", modifiers: .command)

            Button(String(localized: "menu_redo")) {
                performRedo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .pasteboard) {
            Button(String(localized: "cut_subtitle_block")) {
                performCut()
            }
            .keyboardShortcut("x", modifiers: .command)

            Button(String(localized: "copy_subtitle_block")) {
                performCopy()
            }
            .keyboardShortcut("c", modifiers: .command)

            Button(String(localized: "paste_subtitle_block")) {
                performPaste()
            }
            .keyboardShortcut("v", modifiers: .command)

            Button(String(localized: "select_all")) {
                performSelectAll()
            }
            .keyboardShortcut("a", modifiers: .command)
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

            Divider()

            Button(String(localized: "current_media_info")) {
                NotificationCenter.default.post(name: .stropheShowCurrentMediaInfo, object: nil)
            }
        }
        
        CommandGroup(replacing: .saveItem) {
            Button(String(localized: "btn_save")) {
                NotificationCenter.default.post(name: .stropheSaveProject, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)
            
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
            performUndo()
        }

        Button("menu_redo") {
            performRedo()
        }

        Divider()

        Button("cut_subtitle_block") {
            performCut()
        }

        Button("copy_subtitle_block") {
            performCopy()
        }

        Button("paste_subtitle_block") {
            performPaste()
        }

        Divider()

        Button("search_replace_filter") {
            NotificationCenter.default.post(name: .stropheOpenEditingTools, object: nil)
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(project.isEditingText)

        Button("bilingual_comparison_editor") {
            NotificationCenter.default.post(name: .stropheOpenBilingualEditor, object: nil)
        }
        .disabled(project.items.isEmpty)

        Divider()

        Button("markers_and_chapters") {
            NotificationCenter.default.post(name: .stropheShowProjectMarkers, object: nil)
        }

        Button("add_marker") {
            project.addMarker(kind: .marker)
        }
        .timelineShortcut("m", modifiers: [])
        .disabled(project.isEditingText)

        Button("add_chapter") {
            project.addMarker(kind: .chapter)
        }
        .disabled(project.isEditingText)

        Button("set_in_point") {
            project.setInPoint()
        }
        .timelineShortcut("i", modifiers: [])
        .disabled(project.isEditingText)

        Button("set_out_point") {
            project.setOutPoint()
        }
        .timelineShortcut("o", modifiers: [])
        .disabled(project.isEditingText)

        Button("clear_range") {
            project.clearInOutPoints()
        }
        .disabled(
            (project.inPoint == nil && project.outPoint == nil)
                || project.isEditingText
        )

        Button("loop_in_out_range") {
            project.toggleInOutLoop()
        }
        .disabled(
            project.inPoint == nil
                || project.outPoint == nil
                || project.isEditingText
        )

        Button("loop_current_subtitle") {
            project.toggleCurrentSubtitleLoop()
        }
        .timelineShortcut("/", modifiers: [])
        .disabled(project.isEditingText || project.items.isEmpty)

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

    private func isTextEditingOrFocused() -> Bool {
        #if os(macOS)
        guard let keyWindow = NSApp.keyWindow,
              let responder = keyWindow.firstResponder else { return false }
        if responder is NSText || responder is NSTextView || responder is NSTextField {
            return true
        }
        let className = String(describing: type(of: responder))
        return className.contains("Text") || className.contains("Field") || className.contains("Editor") || className.contains("Search")
        #else
        return false
        #endif
    }

    private func performUndo() {
        #if os(macOS)
        if isTextEditingOrFocused() || project.isEditingText {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        } else if project.canUndo {
            project.undo()
        } else {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        }
        #else
        if project.canUndo { project.undo() }
        #endif
    }

    private func performRedo() {
        #if os(macOS)
        if isTextEditingOrFocused() || project.isEditingText {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        } else if project.canRedo {
            project.redo()
        } else {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        }
        #else
        if project.canRedo { project.redo() }
        #endif
    }

    private func performCopy() {
        #if os(macOS)
        if isTextEditingOrFocused() {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        } else if project.canCopySelectedSubtitleBlocks {
            project.copySelectedSubtitleBlocks()
        } else {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        }
        #else
        if project.canCopySelectedSubtitleBlocks { project.copySelectedSubtitleBlocks() }
        #endif
    }

    private func performCut() {
        #if os(macOS)
        if isTextEditingOrFocused() {
            NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        } else if project.canCutSelectedSubtitleBlocks {
            project.cutSelectedSubtitleBlocks()
        } else {
            NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        }
        #else
        if project.canCutSelectedSubtitleBlocks { project.cutSelectedSubtitleBlocks() }
        #endif
    }

    private func performPaste() {
        #if os(macOS)
        if isTextEditingOrFocused() {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        } else if project.canPasteSubtitleBlocks {
            project.pasteSubtitleBlocksIntoActiveGroup()
        } else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        }
        #else
        if project.canPasteSubtitleBlocks { project.pasteSubtitleBlocksIntoActiveGroup() }
        #endif
    }

    private func performSelectAll() {
        #if os(macOS)
        if isTextEditingOrFocused() {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        } else {
            project.selectAllSubtitles()
        }
        #else
        project.selectAllSubtitles()
        #endif
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

        Button("karaoke_batch_recognition_ellipsis") {
            NotificationCenter.default.post(name: .stropheOpenKaraokeBatchRecognition, object: nil)
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
    var onExportEmbeddedSubtitles: () -> Void
    var onExportHardSubtitles: () -> Void
    var onExportDelivery: (SubtitleDeliveryFormat) -> Void
    var onSaveProject: () -> Void
    var onSaveProjectAs: () -> Void
    @Binding var selectedTab: StropheTab

    var body: some ToolbarContent {
        // Left side: back button (on compact iPhone) and import folder
        #if os(iOS)
        ToolbarItemGroup(placement: .topBarLeading) {
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
        }
        #else
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                projectFileMenuItems
            } label: {
                Label("project", systemImage: "folder")
            }
            .help(String(localized: "project_file_operations"))
        }
        #endif

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
        #if os(iOS)
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(action: onSaveProject) {
                Image(systemName: "square.and.arrow.down")
            }
            .help(String(localized: "save_current_project_file"))

            Menu {
                iosOverflowMenuItems
            } label: {
                Image(systemName: "ellipsis")
            }
            .help(String(localized: "more_actions"))
        }
        #else
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: onSaveProject) {
                Label("save", systemImage: "square.and.arrow.down")
            }
            .help(String(localized: "save_current_project_file"))

            Menu {
                exportMenuItems
            } label: {
                Label("export", systemImage: "square.and.arrow.up")
            }
            .help(String(localized: "export_subtitles_or_share_project"))
        }
        #endif
    }

    @ViewBuilder
    private var exportMenuItems: some View {
        Menu {
            Button {
                onExportSoftSubtitles(.srt)
            } label: {
                Label("format_srt", systemImage: "doc.text")
            }
            Button {
                onExportSoftSubtitles(.ass)
            } label: {
                Label("format_ass", systemImage: "doc.richtext")
            }
            Button {
                onExportSoftSubtitles(.lrc)
            } label: {
                Label("format_lrc", systemImage: "music.note.list")
            }
            Button {
                onExportSoftSubtitles(.vtt)
            } label: {
                Label("format_vtt", systemImage: "text.bubble")
            }
        } label: {
            Label("format_soft_subtitles", systemImage: "captions.bubble")
        }

        Divider()

        Menu {
            Button {
                onExportDelivery(.csv)
            } label: {
                Label("format_csv", systemImage: "doc.text")
            }
            Button {
                onExportDelivery(.excel)
            } label: {
                Label("format_excel", systemImage: "tablecells.fill")
            }
            Button {
                onExportDelivery(.fcpxml)
            } label: {
                Label("format_fcpxml", systemImage: "film.stack")
            }
        } label: {
            Label("delivery_data_and_nle", systemImage: "tablecells")
        }

        Divider()

        Button {
            onSaveProjectAs()
        } label: {
            Label("strophe_project_strophe", systemImage: "folder")
        }

        Divider()

        Button {
            onExportEmbeddedSubtitles()
        } label: {
            Label("embedded_soft_subtitle_video_ellipsis", systemImage: "video")
        }
        .disabled(project.videoURL == nil || project.items.isEmpty)

        Button {
            onExportHardSubtitles()
        } label: {
            Label("hard_subtitled_video_ellipsis", systemImage: "film")
        }
        .disabled(project.videoURL == nil || project.items.isEmpty)
    }

    #if os(iOS)
    @ViewBuilder
    private var iosOverflowMenuItems: some View {
        Menu {
            exportMenuItems
        } label: {
            Label("export", systemImage: "square.and.arrow.up")
        }
        .tint(Color.primary)

        Menu {
            iosSubtitleEditingMenuItems
        } label: {
            Label("subtitle_editing_tools", systemImage: "text.magnifyingglass")
        }
        .tint(Color.primary)

        Menu {
            iosMarkersMenuItems
        } label: {
            Label("markers_and_chapters", systemImage: "bookmark")
        }
        .tint(Color.primary)

        Divider()

        Button {
            NotificationCenter.default.post(name: .stropheShowCurrentMediaInfo, object: nil)
        } label: {
            Label("current_media_info", systemImage: "info.square")
        }
    }

    @ViewBuilder
    private var iosSubtitleEditingMenuItems: some View {
        Button {
            NotificationCenter.default.post(name: .stropheOpenEditingTools, object: nil)
        } label: {
            Label("search_replace_filter", systemImage: "magnifyingglass")
        }
        .disabled(project.isEditingText)

        Divider()

        Button {
            project.undo()
        } label: {
            Label("menu_undo", systemImage: "arrow.uturn.backward")
        }
        .disabled(!project.canUndo || project.isEditingText)

        Button {
            project.redo()
        } label: {
            Label("menu_redo", systemImage: "arrow.uturn.forward")
        }
        .disabled(!project.canRedo || project.isEditingText)

        Divider()

        Button {
            project.cutSelectedSubtitleBlocks()
        } label: {
            Label("cut_subtitle_block", systemImage: "scissors")
        }
        .disabled(!project.canCutSelectedSubtitleBlocks || project.isEditingText)

        Button {
            project.copySelectedSubtitleBlocks()
        } label: {
            Label("copy_subtitle_block", systemImage: "doc.on.doc")
        }
        .disabled(!project.canCopySelectedSubtitleBlocks || project.isEditingText)

        Button {
            project.pasteSubtitleBlocksIntoActiveGroup()
        } label: {
            Label("paste_subtitle_block", systemImage: "doc.on.clipboard")
        }
        .disabled(!project.canPasteSubtitleBlocks || project.isEditingText)

        Button {
            project.selectAllSubtitles()
        } label: {
            Label("select_all", systemImage: "checkmark.circle")
        }
        .disabled(project.items.isEmpty || project.isEditingText)

        Divider()

        Button {
            project.seekToSubtitleBoundary(.left)
        } label: {
            Label("align_subtitle_block_left", systemImage: "text.alignleft")
        }
        .disabled(project.items.isEmpty || project.isEditingText)

        Button {
            project.seekToSubtitleBoundary(.right)
        } label: {
            Label("align_subtitle_block_right", systemImage: "text.alignright")
        }
        .disabled(project.items.isEmpty || project.isEditingText)
    }

    @ViewBuilder
    private var iosMarkersMenuItems: some View {
        Button {
            NotificationCenter.default.post(name: .stropheShowProjectMarkers, object: nil)
        } label: {
            Label("markers_and_chapters", systemImage: "list.bullet.rectangle")
        }

        Divider()

        Button {
            project.addMarker(kind: .marker)
        } label: {
            Label("add_marker", systemImage: "bookmark")
        }
        .disabled(project.isEditingText)

        Button {
            project.addMarker(kind: .chapter)
        } label: {
            Label("add_chapter", systemImage: "book.closed")
        }
        .disabled(project.isEditingText)

        Divider()

        Button {
            project.setInPoint()
        } label: {
            Label("set_in_point", systemImage: "arrow.right.to.line")
        }
        .disabled(project.isEditingText)

        Button {
            project.setOutPoint()
        } label: {
            Label("set_out_point", systemImage: "arrow.left.to.line")
        }
        .disabled(project.isEditingText)

        Button(role: .destructive) {
            project.clearInOutPoints()
        } label: {
            Label("clear_range", systemImage: "xmark.rectangle")
        }
        .disabled((project.inPoint == nil && project.outPoint == nil) || project.isEditingText)

        Button {
            project.toggleInOutLoop()
        } label: {
            Label(
                "loop_in_out_range",
                systemImage: project.loopsSelection ? "repeat.circle.fill" : "repeat"
            )
        }
        .disabled(
            project.inPoint == nil
                || project.outPoint == nil
                || project.isEditingText
        )

        Button {
            project.toggleCurrentSubtitleLoop()
        } label: {
            Label("loop_current_subtitle", systemImage: "repeat.1")
        }
        .disabled(project.items.isEmpty || project.isEditingText)
    }
    #endif

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
                            NotificationCenter.default.post(name: .stropheOpenKaraokeBatchRecognition, object: nil)
                        } label: {
                            Label("karaoke_batch_recognition", systemImage: "music.note.list")
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
                    Divider()
                    Button {
                        NotificationCenter.default.post(name: .stropheOpenBilingualEditor, object: nil)
                    } label: {
                        Label("bilingual_comparison_editor", systemImage: "rectangle.split.2x1")
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
