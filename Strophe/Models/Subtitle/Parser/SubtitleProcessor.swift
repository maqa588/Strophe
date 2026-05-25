//
//  SubtitleProcessor.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import Foundation

protocol SubtitleProcessor {
    /// 将导入的纯文本文件解析为标准统一的字幕块数组
    func parse(text: String) -> [SubtitleBlock]
    
    /// 将标准字幕块数组序列化为导出的文本字符串
    func generate(blocks: [SubtitleBlock]) -> String
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
        let hrs = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        
        switch format {
        case .srt:
            return String(format: "%02d:%02d:%02d,%03d", hrs, mins, secs, ms)
        case .ass:
            // ASS 小时只有 1 位，毫秒只保留 2 位
            let cs = ms / 10 // 厘秒
            return String(format: "%1d:%02d:%02d.%02d", hrs, mins, secs, cs)
        case .lrc:
            let totalMins = hrs * 60 + mins
            let cs = ms / 10
            return String(format: "[%02d:%02d.%02d]", totalMins, secs, cs)
        case .vtt:
            return String(format: "%02d:%02d:%02d.%03d", hrs, mins, secs, ms)
        }
    }
}
