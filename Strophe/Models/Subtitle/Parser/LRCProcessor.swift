//
//  LRCProcessor.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import Foundation

struct LRCProcessor: SubtitleProcessor {
    let format: SubtitleFormat = .lrc

    func parseDocument(text: String, sourceFileName: String?) -> SubtitleParseResult {
        var rawBlocks: [(start: TimeInterval, text: String, timestamp: String)] = []
        var metadataLines: [String] = []
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let lines = normalizedText.components(separatedBy: "\n")
        let regex = try? NSRegularExpression(pattern: "\\[(\\d{1,3}):(\\d{2}(?:\\.\\d{1,3})?)\\]")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            let matches = regex?.matches(in: trimmed, options: [], range: range) ?? []
            guard !matches.isEmpty else {
                metadataLines.append(line)
                continue
            }

            var lyricText = trimmed
            for match in matches.reversed() {
                if let timestampRange = Range(match.range(at: 0), in: lyricText) {
                    lyricText.removeSubrange(timestampRange)
                }
            }
            lyricText = lyricText.trimmingCharacters(in: .whitespaces)

            for match in matches {
                guard let timestampRange = Range(match.range(at: 0), in: trimmed) else { continue }
                let timestamp = String(trimmed[timestampRange])
                rawBlocks.append(
                    (
                        start: SubtitleTimeFormatter.parseTimestamp(timestamp, isLRC: true),
                        text: lyricText,
                        timestamp: timestamp
                    )
                )
            }
        }

        rawBlocks.sort { lhs, rhs in
            if lhs.start == rhs.start { return lhs.text < rhs.text }
            return lhs.start < rhs.start
        }

        let source = SubtitleSourceDocument(
            format: .lrc,
            sourceFileName: sourceFileName,
            lrc: LRCDocumentMetadata(metadataLines: metadataLines)
        )
        var completedBlocks: [SubtitleBlock] = []
        for i in 0..<rawBlocks.count {
            let current = rawBlocks[i]
            var endTime = current.start + 3.0
            if i + 1 < rawBlocks.count {
                endTime = max(current.start, rawBlocks[i + 1].start)
            }

            completedBlocks.append(
                SubtitleBlock(
                    startTime: current.start,
                    endTime: endTime,
                    text: current.text,
                    interchangeMetadata: SubtitleCueInterchangeMetadata(
                        sourceDocumentID: source.id,
                        lrc: LRCCueMetadata(originalTimestamp: current.timestamp)
                    )
                )
            )
        }

        return SubtitleParseResult(
            document: SubtitleDocument(format: .lrc, blocks: completedBlocks, source: source)
        )
    }

    func generate(document: SubtitleDocument) -> String {
        var outputLines: [String] = []
        if let source = matchingSource(in: document) {
            outputLines.append(contentsOf: source.lrc?.metadataLines ?? [])
        }
        for block in document.blocks {
            let originalTimestamp = block.interchangeMetadata?.lrc?.originalTimestamp
            let timestamp: String
            if let originalTimestamp,
               abs(
                    SubtitleTimeFormatter.parseTimestamp(originalTimestamp, isLRC: true)
                    - block.startTime
               ) < 0.0005 {
                timestamp = originalTimestamp
            } else {
                timestamp = SubtitleTimeFormatter.format(seconds: block.startTime, format: .lrc)
            }
            outputLines.append("\(timestamp)\(block.text)")
        }
        return outputLines.joined(separator: "\n") + (outputLines.isEmpty ? "" : "\n")
    }

    private func matchingSource(in document: SubtitleDocument) -> SubtitleSourceDocument? {
        guard let source = document.source, source.format == .lrc else { return nil }
        return source
    }
}
