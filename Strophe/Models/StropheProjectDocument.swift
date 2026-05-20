//
//  StropheProjectDocument.swift
//  Strophe
//

import SwiftUI
import UniformTypeIdentifiers

struct StropheProjectDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        guard let type = UTType(filenameExtension: "strophe") else {
            return [.json]
        }
        return [type]
    }
    
    var data: StropheProjectData
    
    init(data: StropheProjectData) {
        self.data = data
    }
    
    nonisolated init(configuration: ReadConfiguration) throws {
        guard let rawData = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoded = try JSONDecoder().decode(StropheProjectData.self, from: rawData)
        self.data = decoded
    }
    
    nonisolated func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoded = try JSONEncoder().encode(data)
        return FileWrapper(regularFileWithContents: encoded)
    }
}
