//
//  MainContentView.swift
//  Strophe
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
    import AppKit
#endif

struct MainContentView: View {
    @ObservedObject var project: SubtitleProject
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    #if os(visionOS)
        @EnvironmentObject private var workspace: SpatialWorkspaceModel
    #endif

    private var isCompactLandscape: Bool {
        #if os(iOS)
            return verticalSizeClass == .compact
        #else
            return false
        #endif
    }


    @State private var isShowingImportMedia = false
    @State private var isShowingExport = false
    @State private var isShowingHardSubtitleExport = false
    @State private var isShowingHardSubtitleExportSettings = false
    @State private var isShowingEmbeddedSubtitleExport = false
    @State private var exportText = ""
    @State private var exportFormat: SubtitleFormat = .srt
    @State private var isShowingDeliveryExport = false
    @State private var deliveryFormat: SubtitleDeliveryFormat = .csv
    @State private var deliveryData = Data()
    @State private var deliveryErrorMessage: String?
    @State private var hardSubtitleSettings = HardSubtitleVideoExportSettings()
    @State private var hardSubtitleSettingsBeforeAlphaPreset: HardSubtitleVideoExportSettings?
    @StateObject private var hardSubtitleExport = HardSubtitleExportCoordinator()
    @StateObject private var embeddedSubtitleExport = EmbeddedSubtitleExportCoordinator()
    @State private var isShowingDiscardProjectAlert = false
    @State private var pendingMediaURL: URL? = nil

    var isCompact: Bool = false
    var path: Binding<NavigationPath> = .constant(NavigationPath())
    var onSaveProject: () -> Void
    var onSaveProjectAs: () -> Void
    @Binding var selectedTab: StropheTab

    init(
        project: SubtitleProject,
        selectedTab: Binding<StropheTab>,
        isCompact: Bool = false,
        path: Binding<NavigationPath> = .constant(NavigationPath()),
        onSaveProject: @escaping () -> Void = {},
        onSaveProjectAs: @escaping () -> Void = {}
    ) {
        self.project = project
        self._selectedTab = selectedTab
        self.isCompact = isCompact
        self.path = path
        self.onSaveProject = onSaveProject
        self.onSaveProjectAs = onSaveProjectAs
    }

    private var stropheUTType: UTType {
        UTType(filenameExtension: "strophe") ?? .json
    }

    private var navigationSubtitle: String {
        guard !project.documentDisplayName.isEmpty else { return "" }
        var title = ""
        if let docName = project.projectURL?.deletingPathExtension().lastPathComponent, !docName.isEmpty {
            title = docName
        } else if let videoName = project.videoURL?.deletingPathExtension().lastPathComponent, !videoName.isEmpty {
            title = videoName
        }
        if project.isDirty {
            title += String(localized: "label_edited")
        }
        return title
    }

    @ViewBuilder
    private var editorVStack: some View {
        VStack(spacing: 0) {
            if isCompactLandscape {
                landscapeVideoPlayerSection
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                #if os(visionOS)
                    videoSurface
                #else
                    VideoPlayerView(
                        project: project,
                        onImportMedia: {
                            requestImportMedia()
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            }

            #if os(visionOS)
                if workspace.isTimelineDetached {
                    DetachedModulePlaceholder(
                        title: "vp_timeline_detached_title",
                        message: "vp_timeline_detached_message",
                        windowID: SpatialWindowID.timeline
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                } else {
                    WaveformTimelineView(project: project)
                        .frame(maxWidth: .infinity)
                }
            #else
                WaveformTimelineView(project: project)
                    .frame(maxWidth: .infinity)
            #endif
        }
        #if os(visionOS)
            .background(.clear)
        #else
            .background(Color.stropheSecondaryBackground)
        #endif
    }

    #if os(visionOS)
        /// The player surface can only live in one UIKit host at a time, so the
        /// embedded copy is replaced by a placeholder while the video window is open.
        @ViewBuilder
        private var videoSurface: some View {
            if workspace.isVideoDetached {
                DetachedModulePlaceholder(
                    title: "vp_video_detached_title",
                    message: "vp_video_detached_message",
                    windowID: SpatialWindowID.video
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VideoPlayerView(
                    project: project,
                    onImportMedia: {
                        requestImportMedia()
                    },
                    suspendsPlaybackOnDisappear: !workspace.isVideoDetached
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    #endif

    @ViewBuilder
    private var exportProgressOverlay: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if let hardSubtitleProgress = hardSubtitleExport.progress {
                exportProgressView(
                    progress: hardSubtitleProgress,
                    title: String(localized: "exporting_hard_subtitled_video"),
                    onCancel: {
                        hardSubtitleExport.cancel()
                    }
                )
            }
            if let embeddedSubtitleProgress = embeddedSubtitleExport.progress {
                exportProgressView(
                    progress: embeddedSubtitleProgress,
                    title: String(localized: "exporting_embedded_subtitle_video")
                )
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var mainBodyContent: some View {
        if isCompactLandscape {
            GeometryReader { geometry in
                let insets = geometry.safeAreaInsets
                let isLeadingDocked = insets.leading > insets.trailing
                let barWidth = max(isLeadingDocked ? insets.leading : insets.trailing, 64)

                HStack(spacing: 0) {
                    if isLeadingDocked {
                        landscapeSideVerticalStrip(isLeading: true)
                            .frame(width: barWidth)

                        editorVStack
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        editorVStack
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        landscapeSideVerticalStrip(isLeading: false)
                            .frame(width: barWidth)
                    }
                }
            }
            .ignoresSafeArea(.container, edges: [.leading, .trailing])
        } else {
            editorVStack
        }
    }

    var body: some View {
        mainBodyContent
            .overlay(alignment: .topTrailing) {
                exportProgressOverlay
            }
        #if os(macOS)
            .navigationTitle(String(localized: "app_name"))
            .navigationSubtitle(navigationSubtitle)
        #else
            .navigationTitle(
                project.documentDisplayName.isEmpty ? String(localized: "app_name") : project.documentDisplayName)
        #endif
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isCompactLandscape ? .hidden : .visible, for: .navigationBar)
            .navigationBarBackButtonHidden(isCompactLandscape)
        #endif
        .toolbar {
            StropheMainToolbar(
                project: project,
                horizontalSizeClass: horizontalSizeClass,
                onExportSoftSubtitles: { format in
                    exportSubtitles(format: format)
                },
                onExportEmbeddedSubtitles: {
                    #if os(macOS)
                        showEmbeddedSubtitleSavePanel()
                    #else
                        isShowingEmbeddedSubtitleExport = true
                    #endif
                },
                onExportHardSubtitles: {
                    prepareHardSubtitleExport()
                },
                onExportAlphaVideo: {
                    prepareAlphaVideoExport()
                },
                onExportDelivery: { format in
                    exportDelivery(format)
                },
                onSaveProject: onSaveProject,
                onSaveProjectAs: onSaveProjectAs,
                selectedTab: $selectedTab
            )

            #if os(visionOS)
                ToolbarItem(placement: .primaryAction) {
                    SpatialLayoutMenu()
                }
            #endif
        }
        #if os(iOS)
            .sheet(isPresented: $isShowingImportMedia) {
                MediaDocumentPicker(
                    allowedContentTypes: UTType.allMediaTypes + [.stropheProject],
                    allowsMultipleSelection: false
                ) { result in
                    isShowingImportMedia = false
                    handleImportMedia(result)
                }
            }
        #else
            .fileImporter(
                isPresented: $isShowingImportMedia,
                allowedContentTypes: UTType.allMediaTypes + [.stropheProject],
                allowsMultipleSelection: false,
                onCompletion: handleImportMedia
            )
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .stropheImportMedia)) { _ in
            requestImportMedia()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheExportSoftSubtitles)) { notification in
            if let format = notification.object as? SubtitleFormat {
                exportSubtitles(format: format)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheExportEmbeddedSubtitles)) { _ in
            #if os(macOS)
                showEmbeddedSubtitleSavePanel()
            #else
                isShowingEmbeddedSubtitleExport = true
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheExportHardSubtitles)) { _ in
            prepareHardSubtitleExport()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheExportAlphaVideo)) { _ in
            prepareAlphaVideoExport()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheExportDelivery)) { notification in
            if let format = notification.object as? SubtitleDeliveryFormat {
                exportDelivery(format)
            }
        }
        .fileExporter(
            isPresented: $isShowingExport,
            document: SubtitleExportDocument(textString: exportText),
            contentType: UTType.fromFormat(exportFormat),
            defaultFilename: "subtitles.\(exportFormat.fileExtension)"
        ) { _ in }
        .fileExporter(
            isPresented: $isShowingDeliveryExport,
            document: BinaryDeliveryDocument(data: deliveryData),
            contentType: deliveryFormat.contentType,
            defaultFilename: "\(deliveryBaseName).\(deliveryFormat.fileExtension)"
        ) { _ in }
        #if os(iOS) || os(visionOS)
            .fileExporter(
                isPresented: $isShowingEmbeddedSubtitleExport,
                document: MediaContainerExportDocument(),
                contentType: .stropheMatroskaVideo,
                defaultFilename: embeddedSubtitleDefaultFilename
            ) { result in
                guard case .success(let url) = result else { return }
                embeddedSubtitleExport.start(project: project, destinationURL: url)
            }
            .fileExporter(
                isPresented: $isShowingHardSubtitleExport,
                document: VideoExportPlaceholderDocument(),
                contentType: hardSubtitleSettings.codec.contentType,
                defaultFilename: hardSubtitleDefaultFilename
            ) { result in
                guard case .success(let url) = result else { return }
                exportHardSubtitleVideo(to: url)
            }
        #endif
        .sheet(isPresented: $isShowingHardSubtitleExportSettings) {
            HardSubtitleExportSettingsSheet(
                settings: $hardSubtitleSettings,
                mediaURL: hardSubtitleSourceURL
            ) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    #if os(macOS)
                        showHardSubtitleSavePanel()
                    #else
                        isShowingHardSubtitleExport = true
                    #endif
                }
            }
        }
        .alert(
            String(localized: "hard_subtitle_export"),
            isPresented: Binding(
                get: { hardSubtitleExport.completionMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        hardSubtitleExport.clearCompletionMessage()
                    }
                }
            ),
            presenting: hardSubtitleExport.completionMessage
        ) { _ in
            Button(String(localized: "ok"), role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert(
            String(localized: "embedded_soft_subtitle_video"),
            isPresented: Binding(
                get: { embeddedSubtitleExport.completionMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        embeddedSubtitleExport.clearCompletionMessage()
                    }
                }
            ),
            presenting: embeddedSubtitleExport.completionMessage
        ) { _ in
            Button(String(localized: "ok"), role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert(
            String(localized: "professional_delivery_export"),
            isPresented: Binding(
                get: { deliveryErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        deliveryErrorMessage = nil
                    }
                }
            ),
            presenting: deliveryErrorMessage
        ) { _ in
            Button(String(localized: "ok"), role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert(
            String(localized: "discard_original_project_confirm"),
            isPresented: $isShowingDiscardProjectAlert
        ) {
            Button(String(localized: "ok_1")) {
                if let url = pendingMediaURL {
                    Task {
                        await project.importMediaAsNewProject(from: url)
                    }
                }
                pendingMediaURL = nil
            }
            Button(String(localized: "cancel"), role: .cancel) {
                pendingMediaURL = nil
            }
        } message: {
            Text(String(localized: "open_new_video_warning"))
        }
    }

    private var hardSubtitleDefaultFilename: String {
        let baseName: String
        if let videoName = project.videoURL?.deletingPathExtension().lastPathComponent, !videoName.isEmpty {
            baseName = videoName
        } else if !project.documentDisplayName.isEmpty {
            baseName = project.documentDisplayName
        } else {
            baseName = "hard-subtitles"
        }
        let qualifier =
            hardSubtitleSettings.rendersTransparentBackground
            ? "alpha"
            : "hard-subtitles"
        return "\(baseName)-\(qualifier).\(hardSubtitleSettings.codec.fileExtension)"
    }

    private var embeddedSubtitleDefaultFilename: String {
        let baseName =
            project.videoURL?
            .deletingPathExtension()
            .lastPathComponent
            ?? (project.documentDisplayName.isEmpty
                ? "subtitles"
                : project.documentDisplayName)
        return "\(baseName)-soft-subtitles.mkv"
    }

    private var hardSubtitleSourceURL: URL? {
        if project.mediaAccessStatus.canRead,
            let resolvedURL = project.mediaAccessStatus.resolvedURL
        {
            return resolvedURL
        }
        guard let videoURL = project.videoURL else { return nil }
        return project.resolveOriginalURL(videoURL)
    }

    private func requestImportMedia() {
        guard !isShowingImportMedia else { return }
        DispatchQueue.main.async {
            isShowingImportMedia = true
        }
    }

    private func handleImportMedia(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        if url.pathExtension.lowercased() == "strophe" {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .stropheOpenProjectWithURL, object: url)
            }
        } else {
            DispatchQueue.main.async {
                if shouldConfirmDiscardCurrentProject {
                    pendingMediaURL = url
                    isShowingDiscardProjectAlert = true
                } else {
                    Task {
                        await project.importMediaAsNewProject(from: url)
                    }
                }
            }
        }
    }

    private var shouldConfirmDiscardCurrentProject: Bool {
        project.videoURL != nil || project.projectURL != nil || !project.items.isEmpty || project.isDirty
    }

    private var hasValidProjectExportRange: Bool {
        guard let start = project.inPoint, let end = project.outPoint else { return false }
        return start.isFinite && end.isFinite && end > start
    }

    private func exportProgressView(
        progress: Double,
        title: String,
        onCancel: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            ProgressView(value: progress)
                .frame(width: 220)
            HStack {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let onCancel {
                    Button(String(localized: "cancel"), role: .cancel) {
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(width: 220)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.stropheBorder.opacity(0.35), lineWidth: 1)
        )
    }

    private func exportSubtitles(format: SubtitleFormat) {
        let generatedText = SubtitleEngine.generate(project.subtitleDocument(for: format))

        exportFormat = format
        exportText = generatedText
        isShowingExport = true
    }

    private func exportDelivery(_ format: SubtitleDeliveryFormat) {
        do {
            deliveryFormat = format
            deliveryData = try SubtitleDeliveryExporter.export(
                project: project,
                format: format
            )
            isShowingDeliveryExport = true
        } catch {
            deliveryErrorMessage = error.localizedDescription
        }
    }

    private func prepareAlphaVideoExport() {
        if hardSubtitleSettingsBeforeAlphaPreset == nil {
            hardSubtitleSettingsBeforeAlphaPreset = hardSubtitleSettings
        }
        hardSubtitleSettings.codec = .proRes4444
        hardSubtitleSettings.exportsTransparentBackground = true
        hardSubtitleSettings.exportsHDR = false
        hardSubtitleSettings.includedAudioTrackOrdinals = []
        hardSubtitleSettings.rangeStartSeconds = project.inPoint
        hardSubtitleSettings.rangeEndSeconds = project.outPoint
        if !hasValidProjectExportRange {
            hardSubtitleSettings.usesProjectRange = false
        }
        isShowingHardSubtitleExportSettings = true
    }

    private func prepareHardSubtitleExport() {
        if let previousSettings = hardSubtitleSettingsBeforeAlphaPreset {
            hardSubtitleSettings = previousSettings
            hardSubtitleSettingsBeforeAlphaPreset = nil
        } else {
            hardSubtitleSettings.exportsTransparentBackground = false
        }
        hardSubtitleSettings.rangeStartSeconds = project.inPoint
        hardSubtitleSettings.rangeEndSeconds = project.outPoint
        if !hasValidProjectExportRange {
            hardSubtitleSettings.usesProjectRange = false
        }
        isShowingHardSubtitleExportSettings = true
    }

    private var deliveryBaseName: String {
        let name = project.documentDisplayName.isEmpty ? "subtitles" : project.documentDisplayName
        return "\(name)-\(deliveryFormat.filenameQualifier)"
    }

    private func exportHardSubtitleVideo(to url: URL) {
        hardSubtitleExport.start(
            project: project,
            settings: hardSubtitleSettings,
            destinationURL: url
        )
    }

    #if os(macOS)
        private func showEmbeddedSubtitleSavePanel() {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = embeddedSubtitleDefaultFilename
            panel.allowedContentTypes = [.stropheMatroskaVideo]
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                embeddedSubtitleExport.start(project: project, destinationURL: url)
            }
        }

        private func showHardSubtitleSavePanel() {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = hardSubtitleDefaultFilename
            panel.allowedContentTypes = [hardSubtitleSettings.codec.contentType]
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                exportHardSubtitleVideo(to: url)
            }
        }
    #endif

    // MARK: - Landscape iMovie-Style Layout

    private func formatLandscapeTime(_ time: Double) -> String {
        let safeTime = time.isFinite ? max(0, time) : 0
        let totalMilliseconds = Int((safeTime * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
        } else {
            return String(format: "%02d:%02d.%03d", minutes, seconds, milliseconds)
        }
    }

    @ViewBuilder
    private var landscapeVideoPlayerSection: some View {
        ZStack {
            VideoPlayerView(
                project: project,
                onImportMedia: {
                    requestImportMedia()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            landscapeTopTitle
            landscapeBottomTimecode
        }
    }

    @ViewBuilder
    private func landscapeSideVerticalStrip(isLeading: Bool) -> some View {
        VStack {
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    selectedTab = .scriptList
                }
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 38, height: 38)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 4, x: 0, y: 1.5)
            }
            .help(String(localized: "back", defaultValue: "返回"))
            .padding(.top, isLeading ? 64 : 8)

            Spacer()

            VStack(spacing: 8) {
                // 1. Export & Save
                Menu {
                    StropheExportMenuItems(
                        project: project,
                        onExportSoftSubtitles: { format in exportSubtitles(format: format) },
                        onExportEmbeddedSubtitles: { isShowingEmbeddedSubtitleExport = true },
                        onExportHardSubtitles: { prepareHardSubtitleExport() },
                        onExportAlphaVideo: { prepareAlphaVideoExport() },
                        onExportDelivery: { format in exportDelivery(format) },
                        onSaveProjectAs: onSaveProjectAs
                    )
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .help(String(localized: "export_subtitles_or_share_project", defaultValue: "导出字幕或保存项目"))

                // 2. Editing & Subtitle Tools
                Menu {
                    Section(String(localized: "editing_tools", defaultValue: "编辑工具")) {
                        Button {
                            NotificationCenter.default.post(name: .stropheOpenEditingTools, object: nil)
                        } label: {
                            Label(String(localized: "subtitle_editing_tools", defaultValue: "字幕编辑工具"), systemImage: "scissors")
                        }
                        Button {
                            NotificationCenter.default.post(name: .stropheOpenAutoLineWrap, object: nil)
                        } label: {
                            Label(String(localized: "auto_line_wrap", defaultValue: "智能换行"), systemImage: "return")
                        }
                        Button {
                            NotificationCenter.default.post(name: .stropheStartSpeechRecognition, object: nil)
                        } label: {
                            Label(String(localized: "speech_recognition_2", defaultValue: "语音识别"), systemImage: "waveform.and.mic")
                        }
                    }
                    Section(String(localized: "assistant_tools", defaultValue: "辅助与特效")) {
                        Button {
                            NotificationCenter.default.post(name: .stropheStartSubtitleTranslation, object: nil)
                        } label: {
                            Label(String(localized: "subtitle_translation_assistant", defaultValue: "字幕翻译助手"), systemImage: "character.bubble")
                        }
                        Button {
                            NotificationCenter.default.post(name: .stropheOpenKaraokeBatchRecognition, object: nil)
                        } label: {
                            Label(String(localized: "karaoke_batch_recognition", defaultValue: "卡拉OK对齐"), systemImage: "music.note.list")
                        }
                        Button {
                            NotificationCenter.default.post(name: .stropheConvertSelectedToPinyin, object: nil)
                        } label: {
                            Label(String(localized: "chinese_to_pinyin", defaultValue: "汉字转拼音"), systemImage: "character.phonetic")
                        }
                    }
                    Section(String(localized: "view_options", defaultValue: "视图预览")) {
                        Toggle(String(localized: "hard_subtitles", defaultValue: "压制字幕预览"), isOn: $project.showHardSubtitles)
                        Toggle(String(localized: "soft_subtitles", defaultValue: "软字幕预览"), isOn: $project.showSoftSubtitles)
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .help(String(localized: "more_actions", defaultValue: "编辑工具"))

                // 3. Add Media / Project
                Menu {
                    Button {
                        requestImportMedia()
                    } label: {
                        Label(String(localized: "import_media", defaultValue: "导入媒体"), systemImage: "photo.badge.plus")
                    }
                    Button {
                        NotificationCenter.default.post(name: .stropheImportScriptFile, object: nil)
                    } label: {
                        Label(String(localized: "import_subtitle_file", defaultValue: "导入字幕文件"), systemImage: "square.and.arrow.down")
                    }
                    Button {
                        NotificationCenter.default.post(name: .strophePasteScript, object: nil)
                    } label: {
                        Label(String(localized: "paste_script", defaultValue: "粘贴文稿"), systemImage: "doc.on.clipboard")
                    }
                    Divider()
                    Button {
                        NotificationCenter.default.post(name: .stropheNewProject, object: nil)
                    } label: {
                        Label(String(localized: "new_project", defaultValue: "新建项目"), systemImage: "plus.square")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .help(String(localized: "project_file_operations", defaultValue: "添加媒体或文稿"))

                // 4. Play / Pause
                Button {
                    project.togglePlayback()
                } label: {
                    Image(systemName: project.playbackRate > 0 ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .help(String(localized: "play_or_pause", defaultValue: "播放/暂停"))

                // 5. Undo / Redo
                Menu {
                    Button {
                        project.undo()
                    } label: {
                        Label(String(localized: "undo", defaultValue: "撤销"), systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!project.canUndo)

                    Button {
                        project.redo()
                    } label: {
                        Label(String(localized: "redo", defaultValue: "重做"), systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!project.canRedo)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(project.canUndo ? Color.primary : Color.secondary.opacity(0.4))
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                } primaryAction: {
                    project.undo()
                }
                .disabled(!project.canUndo)
                .help(String(localized: "undo", defaultValue: "撤销"))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 6, x: 0, y: 2)
            Spacer()
        }
    }

    @ViewBuilder
    private var landscapeTopTitle: some View {
        if !project.documentDisplayName.isEmpty {
            VStack {
                Text(project.documentDisplayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 3, x: 0, y: 1)
                    .padding(.top, 6)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var landscapeBottomTimecode: some View {
        if project.videoURL != nil {
            VStack {
                Spacer()
                TimelineView(
                    .animation(
                        minimumInterval: 1.0 / 30.0,
                        paused: project.playbackRate == 0 && !project.isScrubbing && !project.isSeeking
                    )
                ) { _ in
                    Text(formatLandscapeTime(project.currentTime))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 3, x: 0, y: 1)
                }
                .padding(.bottom, 6)
            }
        }
    }
}
