//
//  SubtitleExportDocument.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    public static func fromFormat(_ format: SubtitleFormat) -> UTType {
        return .plainText
    }
}

// 2. 封装专属的 SwiftUI 导出文档结构体
public struct SubtitleExportDocument: FileDocument {
    public static var readableContentTypes: [UTType] = [.plainText]
    
    public var textString: String
    
    public init(textString: String) {
        self.textString = textString
    }
    
    public init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            self.textString = String(data: data, encoding: .utf8) ?? ""
        } else {
            self.textString = ""
        }
    }
    
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = textString.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
    }
}
