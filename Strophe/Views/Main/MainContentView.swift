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

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayerView(
                project: project,
                onImportMedia: {
                    requestImportMedia()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            WaveformTimelineView(project: project)
                .frame(maxWidth: .infinity)
        }
        .background(Color.stropheSecondaryBackground)
        .overlay(alignment: .topTrailing) {
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
        #if os(macOS)
            .navigationTitle(String(localized: "app_name"))
            .navigationSubtitle(navigationSubtitle)
        #else
            .navigationTitle(
                project.documentDisplayName.isEmpty ? String(localized: "app_name") : project.documentDisplayName)
        #endif
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
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
        #if os(iOS)
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
}
