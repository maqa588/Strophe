//
//  WebVTTProcessor.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/25.
//

import Foundation

struct WebVTTProcessor: SubtitleProcessor {
    func parse(text: String) -> [SubtitleBlock] {
        var blocks: [SubtitleBlock] = []
        // 标准文本按双换行切块，全面兼容 Windows (\r\n) 和 Unix (\n)
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let chunks = normalizedText.components(separatedBy: "\n\n")
        
        for chunk in chunks {
            let lines = chunk.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            
            // WebVTT cue block 必须含有 "-->" 标识
            // 非 cue 块 (例如 NOTE、STYLE、REGION 或 WEBVTT 头部描述) 会被自然过滤
            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timeLine = lines[timeLineIndex]
            
            let parts = timeLine.components(separatedBy: "-->")
            guard parts.count == 2 else { continue }
            
            let startStr = parts[0].trimmingCharacters(in: .whitespaces)
            let endPart = parts[1].trimmingCharacters(in: .whitespaces)
            
            // WebVTT 支持带有设置属性（如 align:middle line:90% 等），我们只需切分并抓取前面的时间戳
            let endTokens = endPart.components(separatedBy: .whitespaces)
            guard let endStr = endTokens.first else { continue }
            
            let startSec = parseWebVTTTimestamp(startStr)
            let endSec = parseWebVTTTimestamp(endStr)
            
            // 将时间轴行之后的所有物理行合流并洗涤格式，组成纯文本字幕
            guard timeLineIndex + 1 < lines.count else { continue }
            let textContent = lines[(timeLineIndex + 1)...].joined(separator: "\n")
            
            // 过滤 WebVTT 内置样式标签，诸如 <b>, <i>, <u>, <c.className>, <v Voice> 等
            let cleanText = textContent
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            blocks.append(SubtitleBlock(startTime: startSec, endTime: endSec, text: cleanText))
        }
        return blocks
    }
    
    func generate(blocks: [SubtitleBlock]) -> String {
        var output = "WEBVTT\n\n"
        for block in blocks {
            let startStr = SubtitleTimeFormatter.format(seconds: block.startTime, format: .vtt)
            let endStr = SubtitleTimeFormatter.format(seconds: block.endTime, format: .vtt)
            output += "\(startStr) --> \(endStr)\n"
            output += "\(block.text)\n\n"
        }
        return output
    }
    
    // 解析 WebVTT 时间戳: [hh:]mm:ss.ttt 或 mm:ss.ttt -> 绝对秒数
    private func parseWebVTTTimestamp(_ string: String) -> TimeInterval {
        let parts = string.split(separator: ":").map { String($0) }
        if parts.count == 3 {
            // hh:mm:ss.ttt
            let hours = Double(parts[0]) ?? 0
            let minutes = Double(parts[1]) ?? 0
            let secondsStr = parts[2].replacingOccurrences(of: ",", with: ".")
            let seconds = Double(secondsStr) ?? 0
            return (hours * 3600) + (minutes * 60) + seconds
        } else if parts.count == 2 {
            // mm:ss.ttt
            let minutes = Double(parts[0]) ?? 0
            let secondsStr = parts[1].replacingOccurrences(of: ",", with: ".")
            let seconds = Double(secondsStr) ?? 0
            return (minutes * 60) + seconds
        } else {
            // 兜底降级处理
            let secondsStr = string.replacingOccurrences(of: ",", with: ".")
            return Double(secondsStr) ?? 0
        }
    }
}
