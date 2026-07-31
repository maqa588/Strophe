//
//  WebVTTProcessor.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/25.
//

import Foundation

struct WebVTTProcessor: SubtitleProcessor {
    let format: SubtitleFormat = .vtt

    func parseDocument(text: String, sourceFileName: String?) -> SubtitleParseResult {
        var blocks: [SubtitleBlock] = []
        var preservedBlocks: [String] = []
        var diagnostics: [SubtitleParseDiagnostic] = []
        let documentID = UUID()
        let normalizedText =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let separated = normalizedText.replacingOccurrences(
            of: "\n[\\t ]*\\n",
            with: "\n\n",
            options: .regularExpression
        )
        let chunks = separated.components(separatedBy: "\n\n")

        for chunk in chunks {
            let normalizedChunk = chunk.trimmingCharacters(in: .newlines)
            guard !normalizedChunk.isEmpty else { continue }
            let lines = normalizedChunk.components(separatedBy: "\n")
            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                preservedBlocks.append(normalizedChunk)
                continue
            }
            let timeLine = lines[timeLineIndex]
            guard let timing = parseTimingLine(timeLine) else {
                diagnostics.append(
                    SubtitleParseDiagnostic(
                        severity: .warning,
                        message: "Skipped a WebVTT cue with an invalid timing line."
                    )
                )
                continue
            }

            let identifier: String?
            if timeLineIndex > 0 {
                let value = lines[..<timeLineIndex]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                identifier = value.isEmpty ? nil : value
            } else {
                identifier = nil
            }

            guard timeLineIndex + 1 < lines.count else { continue }
            let rawPayload = lines[(timeLineIndex + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            let styledText = PreservedStyledText.webVTT(rawPayload)
            blocks.append(
                SubtitleBlock(
                    startTime: timing.start,
                    endTime: timing.end,
                    text: styledText.plainTextAtImport,
                    interchangeMetadata: SubtitleCueInterchangeMetadata(
                        sourceDocumentID: documentID,
                        webVTT: WebVTTCueMetadata(
                            identifier: identifier,
                            settings: timing.settings,
                            styledText: styledText
                        )
                    )
                )
            )
        }

        let source = SubtitleSourceDocument(
            id: documentID,
            format: .vtt,
            sourceFileName: sourceFileName,
            webVTT: WebVTTDocumentMetadata(preservedBlocks: preservedBlocks)
        )
        return SubtitleParseResult(
            document: SubtitleDocument(format: .vtt, blocks: blocks, source: source),
            diagnostics: diagnostics
        )
    }

    func generate(document: SubtitleDocument) -> String {
        var preservedBlocks = document.source?.webVTT?.preservedBlocks ?? []
        if !preservedBlocks.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT")
        }) {
            preservedBlocks.insert("WEBVTT", at: 0)
        }

        var chunks = preservedBlocks
        for block in document.blocks {
            let cue = block.interchangeMetadata?.webVTT
            var lines: [String] = []
            if let identifier = cue?.identifier, !identifier.isEmpty {
                lines.append(identifier)
            }
            let startStr = SubtitleTimeFormatter.format(seconds: block.startTime, format: .vtt)
            let endStr = SubtitleTimeFormatter.format(seconds: block.endTime, format: .vtt)
            let settings = cue?.settings.trimmingCharacters(in: .whitespaces) ?? ""
            lines.append("\(startStr) --> \(endStr)\(settings.isEmpty ? "" : " \(settings)")")
            lines.append(cue?.styledText.encoded(editableText: block.text) ?? block.text)
            chunks.append(lines.joined(separator: "\n"))
        }

        return chunks.joined(separator: "\n\n") + "\n"
    }

    private func parseTimingLine(_ line: String) -> (start: TimeInterval, end: TimeInterval, settings: String)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let startToken = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let rightSide = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        let endToken = rightSide.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard isValidTimestamp(startToken), isValidTimestamp(endToken) else { return nil }
        let settingsStart = rightSide.index(rightSide.startIndex, offsetBy: endToken.count)
        return (
            SubtitleTimeFormatter.parseTimestamp(startToken),
            SubtitleTimeFormatter.parseTimestamp(endToken),
            rightSide[settingsStart...].trimmingCharacters(in: .whitespaces)
        )
    }

    private func isValidTimestamp(_ value: String) -> Bool {
        value.range(
            of: #"^(?:\d{1,3}:)?\d{2}:\d{2}[.]\d{3}$"#,
            options: .regularExpression
        ) != nil
    }
}
