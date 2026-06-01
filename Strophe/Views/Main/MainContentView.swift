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
            // 💡 核心修复 3：左侧按钮组自适应，iPhone 下并排渲染“返回”与“文件夹”
            ToolbarItemGroup(placement: .navigation) {
                #if os(iOS)
                if horizontalSizeClass == .compact {
                    // 📱 iPhone 窄屏：[返回] 与 [文件夹] 纯图标并列呈现
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            selectedTab = .scriptList
                        }
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .help(String(localized: "返回文稿列表"))

                    Button(action: requestImportMedia) {
                        Image(systemName: "folder")
                    }
                    .help(String(localized: "导入媒体文件"))
                } else {
                    // 📱 iPad 宽屏：文件夹
                    Button(action: requestImportMedia) {
                        Image(systemName: "folder")
                    }
                    .help(String(localized: "导入媒体文件"))
                }
                #else
                // 💻 macOS 平台：文件夹（原生 Label）
                Button(action: requestImportMedia) {
                    Label("导入媒体", systemImage: "folder")
                }
                // 💡 核心修复：删除了 .labelStyle(.titleAndIcon)
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

            // Right side: save, export
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: {
                    NotificationCenter.default.post(name: .stropheSaveProject, object: nil)
                }) {
                    #if os(macOS)
                    Label("保存", systemImage: "square.and.arrow.down")
                    // 💡 核心修复：删除了 .labelStyle(.titleAndIcon)
                    #else
                    Image(systemName: "square.and.arrow.down")
                    #endif
                }
                .help(String(localized: "保存当前工程文件"))
                
                
                Menu {
                    Menu("Soft Subtitles") {
                        Button("SubRip (.srt)") {
                            exportSubtitles(format: .srt)
                        }
                        Button("Advanced SubStation Alpha (.ass)") {
                            exportSubtitles(format: .ass)
                        }
                        Button("Lyrics (.lrc)") {
                            exportSubtitles(format: .lrc)
                        }
                        Button("WebVTT (.vtt)") {
                            exportSubtitles(format: .vtt)
                        }
                    }
                    
                    Divider()
                    
                    Button("Strophe Project (.strophe)") {
                        NotificationCenter.default.post(name: .stropheSaveProjectAs, object: nil)
                    }
                    
                    Divider()
                    
                    Button("Hard Subtitled Video…") {
                        isShowingHardSubtitleExportSettings = true
                    }
                    Button("Video Stream (Coming Soon)") {}.disabled(true)
                    Button("Audio Stream (Coming Soon)") {}.disabled(true)
                } label: {
                    #if os(macOS)
                    Label("导出", systemImage: "square.and.arrow.up")
                    // 💡 核心修复：删除了 .labelStyle(.titleAndIcon)
                    #else
                    Image(systemName: "square.and.arrow.up")
                    #endif
                }
                .help(String(localized: "导出字幕或分享项目"))
            }
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
                project.importMedia(from: url)
            }
        }
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
            Text("\(Int((progress * 100).rounded()))%")
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
