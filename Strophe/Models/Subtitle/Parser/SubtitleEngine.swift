//
//  SubtitleEngine.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import Foundation

@MainActor
public final class SubtitleEngine {
    private static let processors: [SubtitleFormat: SubtitleProcessor] = [
        .srt: SRTProcessor(),
        .lrc: LRCProcessor(),
        .ass: ASSProcessor(),
        .vtt: WebVTTProcessor(),
    ]

    /// Reads text with automatic encoding detection and a GB18030 fallback.
    public static func loadRawText(from url: URL) throws -> String {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var estimatedEncoding: String.Encoding = .utf8
        do {
            return try String(contentsOf: url, usedEncoding: &estimatedEncoding)
        } catch {
            let gbkCFEncoding = CFStringEncodings.GB_18030_2000.rawValue
            let gbkEncoding = String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(gbkCFEncoding)))
            return try String(contentsOf: url, encoding: gbkEncoding)
        }
    }

    /// Imports a supported subtitle file into editable cue blocks.
    public static func importSubtitle(from url: URL) throws -> (format: SubtitleFormat, blocks: [SubtitleBlock]) {
        let result = try importDocument(from: url)
        return (result.document.format, result.document.blocks)
    }

    /// Lossless import entry point used by the project editor.
    public static func importDocument(from url: URL) throws -> SubtitleParseResult {
        let pathExtension = url.pathExtension.lowercased()
        guard let format = SubtitleFormat(rawValue: pathExtension) else {
            throw NSError(
                domain: "FormatError", code: -2,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "unsupported_media_file_extension")])
        }

        let rawText = try loadRawText(from: url)
        guard let processor = processors[format] else {
            return SubtitleParseResult(document: SubtitleDocument(format: format, blocks: []))
        }
        return processor.parseDocument(text: rawText, sourceFileName: url.lastPathComponent)
    }

    /// Sniffs pasted text and reports whether it contains a timeline.
    public static func parseAnyText(_ rawText: String) -> (hasTimeline: Bool, blocks: [SubtitleBlock]) {
        let parsed = parseAnyDocument(rawText)
        return (parsed.hasTimeline, parsed.result.document.blocks)
    }

    /// Sniff pasted subtitle text while retaining source metadata.
    public static func parseAnyDocument(
        _ rawText: String
    ) -> (hasTimeline: Bool, result: SubtitleParseResult) {
        if rawText.range(
            of: #"(?im)^\s*Dialogue\s*:"#,
            options: .regularExpression) != nil
        {
            let result = ASSProcessor().parseDocument(text: rawText, sourceFileName: nil)
            if !result.document.blocks.isEmpty {
                return (true, result)
            }
        }

        if rawText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") {
            let result = WebVTTProcessor().parseDocument(text: rawText, sourceFileName: nil)
            if !result.document.blocks.isEmpty {
                return (true, result)
            }
        }

        if rawText.contains("-->") {
            let result = SRTProcessor().parseDocument(text: rawText, sourceFileName: nil)
            if !result.document.blocks.isEmpty {
                return (true, result)
            }
        }

        if rawText.range(of: "\\[\\d{1,3}:\\d{2}", options: .regularExpression) != nil {
            let result = LRCProcessor().parseDocument(text: rawText, sourceFileName: nil)
            if !result.document.blocks.isEmpty {
                return (true, result)
            }
        }

        let lines = rawText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let blocks = lines.map { line in
            SubtitleBlock(startTime: 0, endTime: 0, text: line)
        }
        return (
            false,
            SubtitleParseResult(
                document: SubtitleDocument(format: .srt, blocks: blocks)
            )
        )
    }

    public static func generate(_ document: SubtitleDocument) -> String {
        processors[document.format]?.generate(document: document) ?? ""
    }
}
