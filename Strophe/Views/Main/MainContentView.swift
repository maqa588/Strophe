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
    @State private var exportText = ""
    @State private var exportFormat: SubtitleFormat = .srt
    @State private var hardSubtitleSettings = HardSubtitleVideoExportSettings()
    @State private var hardSubtitleProgress: Double? = nil
    @State private var hardSubtitleExportMessage: String? = nil
    @State private var isShowingHardSubtitleExportAlert = false
    @State private var isShowingDiscardProjectAlert = false
    @State private var pendingMediaURL: URL? = nil
    
    var isCompact: Bool = false
    var path: Binding<NavigationPath> = .constant(NavigationPath())
    @Binding var selectedTab: StropheTab

    init(project: SubtitleProject, selectedTab: Binding<StropheTab>, isCompact: Bool = false, path: Binding<NavigationPath> = .constant(NavigationPath())) {
        self.project = project
        self._selectedTab = selectedTab
        self.isCompact = isCompact
        self.path = path
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
            title += String(localized: " — Edited")
        }
        return title
    }

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayerView(project: project, onImportMedia: {
                requestImportMedia()
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            WaveformTimelineView(project: project)
                .frame(maxWidth: .infinity)
        }
        .background(Color.stropheSecondaryBackground)
        .overlay(alignment: .topTrailing) {
            if let hardSubtitleProgress {
                hardSubtitleProgressView(progress: hardSubtitleProgress)
                    .padding(16)
            }
        }
        #if os(macOS)
        .navigationTitle(String(localized: "Strophe"))
        .navigationSubtitle(navigationSubtitle)
        #else
        .navigationTitle(project.documentDisplayName.isEmpty ? String(localized: "Strophe") : project.documentDisplayName)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            StropheMainToolbar(
                project: project,
                horizontalSizeClass: horizontalSizeClass,
                onImportMedia: {
                    requestImportMedia()
                },
                onExportSoftSubtitles: { format in
                    exportSubtitles(format: format)
                },
                onExportHardSubtitles: {
                    isShowingHardSubtitleExportSettings = true
                },
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
        .fileExporter(
            isPresented: $isShowingExport,
            document: SubtitleExportDocument(textString: exportText),
            contentType: UTType.fromFormat(exportFormat),
            defaultFilename: "subtitles.\(exportFormat.fileExtension)"
        ) { _ in }
        #if os(iOS)
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
            HardSubtitleExportSettingsSheet(settings: $hardSubtitleSettings) {
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
            String(localized: "硬字幕导出"),
            isPresented: $isShowingHardSubtitleExportAlert,
            presenting: hardSubtitleExportMessage
        ) { _ in
            Button(String(localized: "好"), role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert(
            String(localized: "是否要丢弃原工程？"),
            isPresented: $isShowingDiscardProjectAlert
        ) {
            Button(String(localized: "确定")) {
                if let url = pendingMediaURL {
                    project.importMediaAsNewProject(from: url)
                    if let projectURL = project.projectURL {
                        WelcomeRecentProjectsStore.remember(projectURL)
                    }
                }
                pendingMediaURL = nil
            }
            Button(String(localized: "取消"), role: .cancel) {
                pendingMediaURL = nil
            }
        } message: {
            Text(String(localized: "打开新视频会丢弃当前工程，并新建一个与视频文件同名的工程缓存。如果当前工程还没有保存，请先检查保存情况。"))
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
        return "\(baseName)-hard-subtitles.\(hardSubtitleSettings.codec.fileExtension)"
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
                    project.importMediaAsNewProject(from: url)
                    if let projectURL = project.projectURL {
                        WelcomeRecentProjectsStore.remember(projectURL)
                    }
                }
            }
        }
    }

    private var shouldConfirmDiscardCurrentProject: Bool {
        project.videoURL != nil || project.projectURL != nil || !project.items.isEmpty || project.isDirty
    }

    private func hardSubtitleProgressView(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在导出硬字幕视频")
                    .font(.caption.weight(.semibold))
            }
            ProgressView(value: progress)
                .frame(width: 220)
            Text(progress, format: .percent.precision(.fractionLength(0)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.stropheBorder.opacity(0.35), lineWidth: 1)
        )
    }
    
    private func exportSubtitles(format: SubtitleFormat) {
        let blocks = project.items.compactMap { item -> SubtitleBlock? in
            guard let start = item.startTime, let end = item.endTime else { return nil }
            return SubtitleBlock(id: item.id, startTime: start, endTime: end, text: item.text)
        }
        
        let generatedText: String
        switch format {
        case .srt:
            generatedText = SRTProcessor().generate(blocks: blocks)
        case .ass:
            generatedText = ASSProcessor().generate(blocks: blocks)
        case .lrc:
            generatedText = LRCProcessor().generate(blocks: blocks)
        case .vtt:
            generatedText = WebVTTProcessor().generate(blocks: blocks)
        }
        
        exportFormat = format
        exportText = generatedText
        isShowingExport = true
    }

    private func exportHardSubtitleVideo(to url: URL) {
        hardSubtitleProgress = 0
        let didAccessDestination = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if didAccessDestination {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                try await HardSubtitleVideoExporter.export(
                    project: project,
                    settings: hardSubtitleSettings,
                    destinationURL: url
                ) { progress in
                    hardSubtitleProgress = progress
                }
                hardSubtitleExportMessage = String(localized: "导出完成：\(url.lastPathComponent)")
            } catch {
                hardSubtitleExportMessage = error.localizedDescription
            }
            hardSubtitleProgress = nil
            isShowingHardSubtitleExportAlert = true
        }
    }

    #if os(macOS)
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
