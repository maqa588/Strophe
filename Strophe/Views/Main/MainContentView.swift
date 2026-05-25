//
//  MainContentView.swift
//  Strophe
//

import SwiftUI
import UniformTypeIdentifiers

struct MainContentView: View, Equatable {
    @ObservedObject var project: SubtitleProject
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var isShowingImportMedia = false
    @State private var isShowingExport = false
    @State private var exportText = ""
    @State private var exportFormat: SubtitleFormat = .srt
    
    var isCompact: Bool = false
    var path: Binding<NavigationPath> = .constant(NavigationPath())
    @Binding var selectedTab: StropheTab

    static func == (lhs: MainContentView, rhs: MainContentView) -> Bool {
        lhs.project === rhs.project &&
        lhs.isCompact == rhs.isCompact &&
        lhs.selectedTab == rhs.selectedTab
    }

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

                    Button(action: { isShowingImportMedia = true }) {
                        Image(systemName: "folder")
                    }
                    .help(String(localized: "导入媒体文件"))
                } else {
                    // 📱 iPad 宽屏：文件夹
                    Button(action: { isShowingImportMedia = true }) {
                        Image(systemName: "folder")
                    }
                    .help(String(localized: "导入媒体文件"))
                }
                #else
                // 💻 macOS 平台：文件夹（原生 Label）
                Button(action: { isShowingImportMedia = true }) {
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

            // Right side: save, export (+ plus on iPhone)
            ToolbarItemGroup(placement: .primaryAction) {
                #if os(iOS)
                if horizontalSizeClass == .compact {
                    // iPhone: show plus button in the editor toolbar
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
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help(String(localized: "更多操作"))
                }
                #endif

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
                    
                    Button("Hard Subtitles (Coming Soon)") {}.disabled(true)
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
        case .vtt:
            generatedText = WebVTTProcessor().generate(blocks: blocks)
        }
        
        exportFormat = format
        exportText = generatedText
        isShowingExport = true
    }
}
