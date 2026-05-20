//
//  LRCProcessor.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import Foundation

struct LRCProcessor: SubtitleProcessor {
    func parse(text: String) -> [SubtitleBlock] {
        var rawBlocks: [(start: TimeInterval, text: String)] = []
        let lines = text.components(separatedBy: .newlines)
        
        // 正则匹配 [01:23.45] 或 [01:23.456]
        let regex = try? NSRegularExpression(pattern: "\\[(\\d{2}):(\\d{2}\\.\\d{2,3})\\]")
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex?.firstMatch(in: trimmed, options: [], range: range) {
                if let timeRange = Range(match.range(at: 0), in: trimmed) {
                    let timestampStr = String(trimmed[timeRange])
                    let startSec = SubtitleTimeFormatter.parseTimestamp(timestampStr, isLRC: true)
                    let remainingText = trimmed.replacingCharacters(in: timeRange, with: "").trimmingCharacters(in: .whitespaces)
                    
                    rawBlocks.append((start: startSec, text: remainingText))
                }
            }
        }
        
        // 按时间保序排序，防止部分 LRC 时间错乱
        rawBlocks.sort { $0.start < $1.start }
        
        var completedBlocks: [SubtitleBlock] = []
        for i in 0..<rawBlocks.count {
            let current = rawBlocks[i]
            var endTime = current.start + 3.0 // 最后一行的保底闭合时间：默认延展 3 秒
            
            if i + 1 < rawBlocks.count {
                endTime = rawBlocks[i+1].start // 🟢 前瞻：下一句的开端就是当前句的结尾
            }
            
            completedBlocks.append(SubtitleBlock(startTime: current.start, endTime: endTime, text: current.text))
        }
        return completedBlocks
    }
    
    func generate(blocks: [SubtitleBlock]) -> String {
        var output = ""
        for block in blocks {
            output += "\(SubtitleTimeFormatter.format(seconds: block.startTime, format: .lrc))\(block.text)\n"
        }
        return output
    }
}
