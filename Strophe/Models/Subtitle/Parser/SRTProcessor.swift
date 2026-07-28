//
//  SRTProcessor.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import Foundation

struct SRTProcessor: SubtitleProcessor {
    let format: SubtitleFormat = .srt

    func parseDocument(text: String, sourceFileName: String?) -> SubtitleParseResult {
        var blocks: [SubtitleBlock] = []
        var diagnostics: [SubtitleParseDiagnostic] = []
        let source = SubtitleSourceDocument(format: .srt, sourceFileName: sourceFileName)
        let normalizedText = text
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
            let lines = chunk.components(separatedBy: "\n")
            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let timing = parseTimingLine(lines[timeLineIndex]) else {
                if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    diagnostics.append(
                        SubtitleParseDiagnostic(
                            severity: .warning,
                            message: "Skipped an SRT block without a valid timing line."
                        )
                    )
                }
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

            let payloadStart = timeLineIndex + 1
            guard payloadStart < lines.count else { continue }
            let textContent = lines[payloadStart...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            let metadata = SubtitleCueInterchangeMetadata(
                sourceDocumentID: source.id,
                srt: SRTCueMetadata(identifier: identifier, timingSuffix: timing.suffix)
            )
            blocks.append(
                SubtitleBlock(
                    startTime: timing.start,
                    endTime: timing.end,
                    text: textContent,
                    interchangeMetadata: metadata
                )
            )
        }

        return SubtitleParseResult(
            document: SubtitleDocument(format: .srt, blocks: blocks, source: source),
            diagnostics: diagnostics
        )
    }

    func generate(document: SubtitleDocument) -> String {
        var output = ""
        for (index, block) in document.blocks.enumerated() {
            let cue = block.interchangeMetadata?.srt
            let identifier = cue?.identifier?.trimmingCharacters(in: .newlines)
            output += "\((identifier?.isEmpty == false ? identifier : nil) ?? String(index + 1))\n"
            output += "\(SubtitleTimeFormatter.format(seconds: block.startTime, format: .srt)) --> \(SubtitleTimeFormatter.format(seconds: block.endTime, format: .srt))\n"
            if let suffix = cue?.timingSuffix, !suffix.isEmpty {
                output.removeLast()
                output += " \(suffix)\n"
            }
            output += "\(block.text)\n\n"
        }
        return output
    }

    private func parseTimingLine(_ line: String) -> (start: TimeInterval, end: TimeInterval, suffix: String)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let startToken = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let rightSide = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        let endToken = rightSide.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard startToken.range(
            of: #"^\d{1,3}:\d{2}:\d{2}[,.]\d{1,3}$"#,
            options: .regularExpression
        ) != nil,
        endToken.range(
            of: #"^\d{1,3}:\d{2}:\d{2}[,.]\d{1,3}$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }

        let suffixStart = rightSide.index(rightSide.startIndex, offsetBy: endToken.count)
        let suffix = rightSide[suffixStart...].trimmingCharacters(in: .whitespaces)
        return (
            SubtitleTimeFormatter.parseTimestamp(startToken),
            SubtitleTimeFormatter.parseTimestamp(endToken),
            suffix
        )
    }
}
