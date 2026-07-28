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

// 时间格式化公共辅助工具（解耦核心算法）
struct SubtitleTimeFormatter {
    // 解析时间戳字符串为秒数 (例如 "01:23:45,678" -> 5025.678)
    static func parseTimestamp(_ string: String, delimiter: String = ",", isLRC: Bool = false) -> TimeInterval {
        let scanner = Scanner(string: string)
        if isLRC {
            // LRC 格式: [mm:ss.xx] 或 [mm:ss.xxx]
            var minutes: Double = 0
            var seconds: Double = 0
            _ = scanner.scanString("[")
            minutes = scanner.scanDouble() ?? 0
            _ = scanner.scanString(":")
            seconds = scanner.scanDouble() ?? 0
            return (minutes * 60) + seconds
        } else {
            // SRT/ASS 格式: hh:mm:ss
            var hours: Double = 0
            var minutes: Double = 0
            var seconds: Double = 0
            hours = scanner.scanDouble() ?? 0
            _ = scanner.scanString(":")
            minutes = scanner.scanDouble() ?? 0
            _ = scanner.scanString(":")
            // 兼容 ASS 的点 '.' 和 SRT 的逗号 ','
            let cleanedSecondsStr = string.components(separatedBy: ":").last?
                .replacingOccurrences(of: ",", with: ".") ?? "0"
            seconds = Double(cleanedSecondsStr) ?? 0
            return (hours * 3600) + (minutes * 60) + seconds
        }
    }
    
    // 秒数转字符串辅助
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
