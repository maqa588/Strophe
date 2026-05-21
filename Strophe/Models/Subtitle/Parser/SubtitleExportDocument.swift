import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    public static let srtSubtitle = UTType("public.srt") ?? .plainText
    public static let assSubtitle = UTType("public.ass") ?? .plainText
    public static let lrcSubtitle = UTType("public.lrc") ?? .plainText
    public static let stropheProject = UTType("top.maqa.Strophe.strophe-project") ?? UTType(exportedAs: "top.maqa.Strophe.strophe-project", conformingTo: .data)

    public static func fromFormat(_ format: SubtitleFormat) -> UTType {
        switch format {
        case .srt: return .srtSubtitle
        case .ass: return .assSubtitle
        case .lrc: return .lrcSubtitle
        }
    }

    public static var allSubtitleTypes: [UTType] {
        // 💡 只有这些合法的、并在 Info 中备案过的文本类型才会被激活
        // .plainText 会自动匹配您的 .txt 文件
        [.srtSubtitle, .assSubtitle, .lrcSubtitle, .plainText]
    }

    public static var allMediaTypes: [UTType] {
        let videoTypes: [UTType] = ([
            .movie,
            .video,
            UTType("org.matroska.mkv"),
            UTType("org.webmproject.webm"),
            UTType("public.avi"),
            UTType("com.adobe.flash.video"),
            UTType("public.rmvb")
        ] as [UTType?]).compactMap { $0 }
        let audioTypes: [UTType] = ([
            UTType.mp3,
            UTType.mpeg4Audio,
            UTType.wav,
            UTType.aiff,
            UTType("com.apple.coreaudio-format"),
            UTType("public.flac"),
            UTType("public.ogg-audio"),
            UTType("public.aac-audio")
        ] as [UTType?]).compactMap { $0 }
        return videoTypes + audioTypes
    }
}
public struct SubtitleExportDocument: FileDocument {
    public static var readableContentTypes: [UTType] = [.plainText]

    public static var writableContentTypes: [UTType] = [
        .plainText,
        .srtSubtitle,
        .assSubtitle,
        .lrcSubtitle
    ]

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
