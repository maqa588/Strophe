//
//  SubtitleProcessor.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import Foundation

protocol SubtitleProcessor {
    var format: SubtitleFormat { get }

    /// Parse editable cue text and retain lossless source metadata.
    func parseDocument(text: String, sourceFileName: String?) -> SubtitleParseResult

    /// Serialize a document, reusing retained metadata where possible.
    func generate(document: SubtitleDocument) -> String
}

extension SubtitleProcessor {
    func parse(text: String) -> [SubtitleBlock] {
        parseDocument(text: text, sourceFileName: nil).document.blocks
    }

    func generate(blocks: [SubtitleBlock]) -> String {
        generate(document: SubtitleDocument(format: format, blocks: blocks))
    }
}

struct SubtitleTimeFormatter {
    /// Parses LRC, SRT, ASS, or WebVTT timestamps into seconds.
    static func parseTimestamp(_ string: String, isLRC: Bool = false) -> TimeInterval {
        let normalized =
            string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: isLRC ? "[]" : ""))
            .replacingOccurrences(of: ",", with: ".")
        let rawComponents = normalized.split(separator: ":", omittingEmptySubsequences: false)
        let components = rawComponents.compactMap { component -> Double? in
            guard let value = Double(component), value.isFinite, value.sign != .minus else { return nil }
            return value
        }
        guard components.count == rawComponents.count else { return 0 }

        let result: TimeInterval
        switch components.count {
        case 1:
            result = components[0]
        case 2:
            guard components[1] < 60 else { return 0 }
            result = components[0] * 60 + components[1]
        case 3:
            guard components[1] < 60, components[2] < 60 else { return 0 }
            result = components[0] * 3_600 + components[1] * 60 + components[2]
        default:
            return 0
        }
        return result.isFinite ? result : 0
    }

    static func format(seconds: TimeInterval, format: SubtitleFormat) -> String {
        let safeSeconds = max(0, seconds.isFinite ? seconds : 0)

        switch format {
        case .srt:
            let totalMilliseconds = Int((safeSeconds * 1000).rounded())
            let milliseconds = totalMilliseconds % 1000
            let totalSeconds = totalMilliseconds / 1000
            let wholeSeconds = totalSeconds % 60
            let minutes = (totalSeconds / 60) % 60
            let hours = totalSeconds / 3600
            return String(
                format: "%02d:%02d:%02d,%03d",
                hours,
                minutes,
                wholeSeconds,
                milliseconds
            )
        case .ass:
            let totalCentiseconds = Int((safeSeconds * 100).rounded())
            let centiseconds = totalCentiseconds % 100
            let totalSeconds = totalCentiseconds / 100
            return String(
                format: "%d:%02d:%02d.%02d",
                totalSeconds / 3600,
                (totalSeconds / 60) % 60,
                totalSeconds % 60,
                centiseconds
            )
        case .lrc:
            let totalCentiseconds = Int((safeSeconds * 100).rounded())
            let centiseconds = totalCentiseconds % 100
            let totalSeconds = totalCentiseconds / 100
            return String(
                format: "[%02d:%02d.%02d]",
                totalSeconds / 60,
                totalSeconds % 60,
                centiseconds
            )
        case .vtt:
            let totalMilliseconds = Int((safeSeconds * 1000).rounded())
            let milliseconds = totalMilliseconds % 1000
            let totalSeconds = totalMilliseconds / 1000
            return String(
                format: "%02d:%02d:%02d.%03d",
                totalSeconds / 3600,
                (totalSeconds / 60) % 60,
                totalSeconds % 60,
                milliseconds
            )
        }
    }
}
