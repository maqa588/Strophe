//
//  MainContentView.swift
//  Strophe
//

import SwiftUI
import UniformTypeIdentifiers

struct MainContentView: View {
    @ObservedObject var project: SubtitleProject
    @Environment(\.horizontalSizeClass) var sizeClass

    @State private var isShowingImportMedia = false
    @State private var isShowingExport = false
    @State private var exportText = ""
    @State private var exportFormat: SubtitleFormat = .srt
    
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
                isShowingImportMedia = true
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            WaveformTimelineView(project: project)
                .frame(maxWidth: .infinity)
        }
        .background(Color.stropheSecondaryBackground)
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
                if sizeClass == .compact {
                    // 📱 iPhone 窄屏：[返回] 与 [文件夹] 纯图标并列呈现
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            selectedTab = .scriptList
                        }
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    
                    Button(action: { isShowingImportMedia = true }) {
                        Image(systemName: "folder")
                    }
                } else {
                    // 📱 iPad 宽屏：文件夹
                    Button(action: { isShowingImportMedia = true }) {
                        Image(systemName: "folder")
                    }
                }
                #else
                // 💻 macOS 平台：文件夹
                Button(action: { isShowingImportMedia = true }) {
                    Image(systemName: "folder")
                }
                .help(String(localized: "导入媒体文件"))
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

            // 💡 2. 顶栏右侧按钮：纯图标保存与分享
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: {
                    NotificationCenter.default.post(name: .stropheSaveProject, object: nil)
                }) {
                    Image(systemName: "arrow.down.to.line")
                }
                .help(String(localized: "保存当前文稿"))
                
                
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
                    }
                    
                    Divider()
                    
                    Button("Strophe Project (.strophe)") {
                        NotificationCenter.default.post(name: .stropheSaveProjectAs, object: nil)
                    }
                    
                    Divider()
                    
                    Button("Hard Subtitles (Coming Soon)") {}.disabled(true)
                    Button("Video Stream (Coming Soon)") {}.disabled(true)
                    Button("Audio Stream (Coming Soon)") {}.disabled(true)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help(String(localized: "分享与导出项目"))
            }
        }
        .fileImporter(
            isPresented: $isShowingImportMedia,
            allowedContentTypes: UTType.allMediaTypes + [.stropheProject],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                if url.pathExtension.lowercased() == "strophe" {
                    NotificationCenter.default.post(name: .stropheOpenProjectWithURL, object: url)
                } else {
                    project.importMedia(from: url)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheImportMedia)) { _ in
            isShowingImportMedia = true
        }
        .fileExporter(
            isPresented: $isShowingExport,
            document: SubtitleExportDocument(textString: exportText),
            contentType: UTType.fromFormat(exportFormat),
            defaultFilename: "subtitles.\(exportFormat.fileExtension)"
        ) { _ in }
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
        }
        
        exportFormat = format
        exportText = generatedText
        isShowingExport = true
    }
}
