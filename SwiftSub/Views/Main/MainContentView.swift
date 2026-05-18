//
//  MainContentView.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
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
    
    var isCompact: Bool = false
    var path: Binding<NavigationPath> = .constant(NavigationPath())

    var body: some View {
        VStack(spacing: 0) {
            // Video fills all remaining space
            VideoPlayerView(project: project, onImportMedia: { isShowingImportMedia = true })
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Timeline self-sizing at bottom
            WaveformTimelineView(project: project)
                .frame(maxWidth: .infinity)
        }
        .navigationTitle("SwiftSub")
        #if os(macOS)
        .navigationSubtitle(project.videoURL?.lastPathComponent ?? "")
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // MARK: - Native Toolbar
        .toolbar {
            // Left: folder button and Document button (on iPhone)
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 16) {
                    if isCompact {
                        Button(action: { path.wrappedValue.append("script") }) {
                            Image(systemName: "doc.text")
                        }
                    }
                    
                    Button(action: { isShowingOpenProject = true }) {
                        Image(systemName: "folder")
                    }
                }
            }

            #if os(iOS)
            // iPadOS: centred filename / app name via .principal
            ToolbarItem(placement: .principal) {
                Text(project.videoURL?.lastPathComponent ?? "SwiftSub")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(project.videoURL != nil ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            #endif

            // Right: Save / Export
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { isShowingSaveProject = true }) {
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
                    
                    Button("Hard Subtitles (Coming Soon)") {
                        // Placeholder
                    }
                    .disabled(true)
                    
                    Button("Video Stream (Coming Soon)") {
                        // Placeholder
                    }
                    .disabled(true)
                    
                    Button("Audio Stream (Coming Soon)") {
                        // Placeholder
                    }
                    .disabled(true)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .fileImporter(
            isPresented: $isShowingOpenProject,
            allowedContentTypes: [UTType(filenameExtension: "subsub")!],
            allowsMultipleSelection: false
        ) { result in
            DispatchQueue.main.async {
                if case .success(let urls) = result, let url = urls.first {
                    try? project.load(from: url)
                }
            }
        }
        .fileImporter(
            isPresented: $isShowingImportMedia,
            allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie, .audio, .mp3, .item],
            allowsMultipleSelection: false
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        if url.startAccessingSecurityScopedResource() {
                            project.videoURL = url
                        } else {
                            project.videoURL = url
                        }
                    }
                case .failure(let error):
                    print("Import failed: \(error.localizedDescription)")
                }
            }
        }
        .fileExporter(
            isPresented: $isShowingSaveProject,
            document: project.document,
            contentType: UTType(filenameExtension: "subsub")!,
            defaultFilename: "project.subsub"
        ) { result in
            // Handle save result
        }
        .fileExporter(
            isPresented: $isShowingExport,
            document: SubtitleExportDocument(textString: exportText),
            contentType: UTType.fromFormat(exportFormat),
            defaultFilename: "subtitles.\(exportFormat.fileExtension)"
        ) { result in
            // Handle export result
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
