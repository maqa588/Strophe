//
//  SRTProcessor.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import Foundation

struct SRTProcessor: SubtitleProcessor {
    func parse(text: String) -> [SubtitleBlock] {
        var blocks: [SubtitleBlock] = []
        // 标准文本按双换行切块，全面兼容 Windows (\r\n) 和 Unix (\n)
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        let chunks = normalizedText.components(separatedBy: "\n\n")
        
        let regex = try? NSRegularExpression(pattern: "(\\d{2}:\\d{2}:\\d{2},\\d{3})\\s-->\\s(\\d{2}:\\d{2}:\\d{2},\\d{3})")
        
        for chunk in chunks {
            let lines = chunk.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard lines.count >= 3 else { continue }
            
            let timeLine = lines[1]
            let range = NSRange(timeLine.startIndex..<timeLine.endIndex, in: timeLine)
            
            if let match = regex?.firstMatch(in: timeLine, options: [], range: range) {
                if let startRange = Range(match.range(at: 1), in: timeLine),
                   let endRange = Range(match.range(at: 2), in: timeLine) {
                    
                    let startSec = SubtitleTimeFormatter.parseTimestamp(String(timeLine[startRange]))
                    let endSec = SubtitleTimeFormatter.parseTimestamp(String(timeLine[endRange]))
                    
                    // 合并后续所有行作为文本（防止歌词或对白本身自带单换行）
                    let textContent = lines[2...].joined(separator: "\n")
                    
                    blocks.append(SubtitleBlock(startTime: startSec, endTime: endSec, text: textContent))
                }
            }
        }
        return blocks
    }
    
    func generate(blocks: [SubtitleBlock]) -> String {
        var output = ""
        for (index, block) in blocks.enumerated() {
            output += "\(index + 1)\n"
            output += "\(SubtitleTimeFormatter.format(seconds: block.startTime, format: .srt)) --> \(SubtitleTimeFormatter.format(seconds: block.endTime, format: .srt))\n"
            output += "\(block.text)\n\n"
        }
        return output
    }
}
