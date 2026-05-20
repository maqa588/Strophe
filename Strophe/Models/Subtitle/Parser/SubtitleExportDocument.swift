import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    public static let srtSubtitle = UTType(filenameExtension: "srt", conformingTo: .text)!
    public static let assSubtitle = UTType(filenameExtension: "ass", conformingTo: .text)!
    public static let lrcSubtitle = UTType(filenameExtension: "lrc", conformingTo: .text)!

    public static func fromFormat(_ format: SubtitleFormat) -> UTType {
        switch format {
        case .srt: return .srtSubtitle
        case .ass: return .assSubtitle
        case .lrc: return .lrcSubtitle
        }
    }

    public static var allSubtitleTypes: [UTType] {
        [.srtSubtitle, .assSubtitle, .lrcSubtitle, .plainText]
    }
}

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
