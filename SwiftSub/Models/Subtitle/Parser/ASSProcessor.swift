//
//  ASSProcessor.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import Foundation

struct ASSProcessor: SubtitleProcessor {
    func parse(text: String) -> [SubtitleBlock] {
        var blocks: [SubtitleBlock] = []
        let lines = text.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // 专注于对白行，无视 [Script Info] 或 [V4+ Styles] 样式头
            guard trimmed.hasPrefix("Dialogue:") else { continue }
            
            // 剥离 "Dialogue:" 前缀
            let record = trimmed.replacingOccurrences(of: "Dialogue:", with: "").trimmingCharacters(in: .whitespaces)
            // ASS 标准：Dialogue: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            // 前面有 9 个逗号分隔的属性，第 10 个字段往后才是真正的文本内容
            let fields = record.components(separatedBy: ",")
            guard fields.count >= 10 else { continue }
            
            let startTimeStr = fields[1].trimmingCharacters(in: .whitespaces)
            let endTimeStr = fields[2].trimmingCharacters(in: .whitespaces)
            
            let startSec = SubtitleTimeFormatter.parseTimestamp(startTimeStr)
            let endSec = SubtitleTimeFormatter.parseTimestamp(endTimeStr)
            
            // 重新拼接可能包含逗号的对白文本内容
            let rawText = fields[9...].joined(separator: ",")
            
            // 🧼 核心无视样式：使用正则，将所有大括号 {} 及其内部的特殊属性特效过滤个一干二净！
            let cleanText = rawText.replacingOccurrences(of: "\\{[^}]+\\}", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\N", with: "\n") // ASS 的换行符是 \N，替换回原生系统换行
            
            blocks.append(SubtitleBlock(startTime: startSec, endTime: endSec, text: cleanText.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return blocks
    }
    
    func generate(blocks: [SubtitleBlock]) -> String {
        // 构建满足底层渲染的最基本简易无样式格式头
        var output = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080
        
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1
        
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        """
        
        for block in blocks {
            let startStr = SubtitleTimeFormatter.format(seconds: block.startTime, format: .ass)
            let endStr = SubtitleTimeFormatter.format(seconds: block.endTime, format: .ass)
            // 将真实系统的物理换行符编码为 ASS 看得懂的 \N
            let encodedText = block.text.replacingOccurrences(of: "\n", with: "\\N")
            
            output += "\nDialogue: 0,\(startStr),\(endStr),Default,,0,0,0,,\(encodedText)"
        }
        return output
    }
}
