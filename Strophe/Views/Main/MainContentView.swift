//
//  MainContentView.swift
//  Strophe
//

import SwiftUI
import UniformTypeIdentifiers

struct MainContentView: View {
    @ObservedObject var project: SubtitleProject

    @State private var isShowingOpenProject = false
    @State private var isShowingSaveProject = false
    @State private var isShowingExport = false
    @State private var exportText = ""
    @State private var exportFormat: SubtitleFormat = .srt
    @State private var isShowingImportMedia = false
    @State private var isShowingConfirmNewProject = false
    
    var isCompact: Bool = false
    var path: Binding<NavigationPath> = .constant(NavigationPath())

    private var stropheUTType: UTType {
        UTType(filenameExtension: "strophe") ?? .json
    }
    
    private var navigationSubtitle: String {
        var title = ""
        if let docName = project.projectURL?.deletingPathExtension().lastPathComponent, !docName.isEmpty {
            title = docName
        } else if let videoName = project.videoURL?.deletingPathExtension().lastPathComponent, !videoName.isEmpty {
            title = videoName
        }
        if project.isDirty {
            title += " — Edited"
        }
        return title
    }

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayerView(project: project, onImportMedia: { isShowingImportMedia = true })
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            WaveformTimelineView(project: project)
                .frame(maxWidth: .infinity)
        }
        .background(Color.stropheSecondaryBackground)
        .navigationTitle("Strophe")
        #if os(macOS)
        .navigationSubtitle(navigationSubtitle)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 16) {
                    if isCompact {
                        Button(action: { path.wrappedValue.append("script") }) {
                            Image(systemName: "doc.text")
                        }
                    }
                    
                    Button(action: {
                        if project.videoURL != nil || !project.items.isEmpty {
                            if project.isDirty, project.projectURL != nil {
                                Task { await project.performAutoSave() }
                            }
                            isShowingConfirmNewProject = true
                        } else {
                            isShowingImportMedia = true
                        }
                    }) {
                        Image(systemName: "folder")
                    }
                }
            }

            #if os(iOS)
            ToolbarItem(placement: .principal) {
                Text(project.videoURL?.lastPathComponent ?? "Strophe")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(project.videoURL != nil ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            #endif

            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: {
                    NotificationCenter.default.post(name: .stropheSaveProject, object: nil)
                }) {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                
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
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .fileImporter(
            isPresented: $isShowingOpenProject,
            allowedContentTypes: [stropheUTType],
            allowsMultipleSelection: false
        ) { result in
            handleOpenProject(result)
        }
        .fileImporter(
            isPresented: $isShowingImportMedia,
            allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie, .audio, .mp3, .item, stropheUTType],
            allowsMultipleSelection: false
        ) { result in
            handleImportMedia(result)
        }
        .fileExporter(
            isPresented: $isShowingSaveProject,
            document: project.document,
            contentType: UTType(filenameExtension: "subsub")!,
            defaultFilename: "project.subsub"
        ) { _ in }
        .fileExporter(
            isPresented: $isShowingExport,
            document: SubtitleExportDocument(textString: exportText),
            contentType: UTType.fromFormat(exportFormat),
            defaultFilename: "subtitles.\(exportFormat.fileExtension)"
        ) { _ in }
        .confirmationDialog(
            String(localized: "是否打开新工程？"),
            isPresented: $isShowingConfirmNewProject,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Open")) {
                isShowingImportMedia = true
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "当前工程未保存的更改将丢失。"))
        }
        .onAppear {}
    }
    
    private func handleOpenProject(_ result: Result<[URL], Error>) {
        DispatchQueue.main.async {
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                try? await project.loadStrophe(from: url)
                project.startAutoSave()
            }
        }
    }
    
    private func handleImportMedia(_ result: Result<[URL], Error>) {
        DispatchQueue.main.async {
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if url.pathExtension.lowercased() == "strophe" {
                    Task {
                        try? await project.loadStrophe(from: url)
                        project.startAutoSave()
                    }
                    return
                }
                project.pause()
                TempCleanupHelper.cleanupTempDirectory()
                project.resetForNewMedia()
                project.prepareMediaAccess(for: url)
                project.videoURL = url
            case .failure(let error):
                print("Import failed: \(error.localizedDescription)")
            }
        }
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
