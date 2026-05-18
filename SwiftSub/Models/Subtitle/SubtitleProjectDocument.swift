//
//  SubtitleProjectDocument.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import SwiftUI
import UniformTypeIdentifiers

struct SubtitleProjectDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "subsub")!] }
    
    var items: [SubtitleItem]
    var videoURL: URL?
    
    init(items: [SubtitleItem], videoURL: URL?) {
        self.items = items
        self.videoURL = videoURL
    }
    
    nonisolated init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoded = try JSONDecoder().decode(SubtitleProjectData.self, from: data)
        self.items = decoded.items
        self.videoURL = decoded.videoURL
    }
    
    nonisolated func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = SubtitleProjectData(items: items, videoURL: videoURL)
        let encoded = try JSONEncoder().encode(data)
        return FileWrapper(regularFileWithContents: encoded)
    }
}

extension SubtitleProject {
    var document: SubtitleProjectDocument {
        SubtitleProjectDocument(items: items, videoURL: videoURL)
    }
}
