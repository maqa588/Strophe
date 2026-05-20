//
//  SubtitleEngine.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import Foundation

@MainActor
public final class SubtitleEngine {
    /// 核心路由字典
    private static let processors: [SubtitleFormat: SubtitleProcessor] = [
        .srt: SRTProcessor(),
        .lrc: LRCProcessor(),
        .ass: ASSProcessor()
    ]
    
    /// 自动嗅探文件编码读取，防止中文乱码崩溃
    public static func loadRawText(from url: URL) throws -> String {
        // 1. 获取文件的安全读取控制权 (安全检查：如果是本地普通文件，startAccessingSecurityScopedResource 哪怕返回 false 也可以直接读取)
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        var estimatedEncoding: String.Encoding = .utf8
        do {
            // 优先用 BOM 和标准 UTF-8 嗅探
            return try String(contentsOf: url, usedEncoding: &estimatedEncoding)
        } catch {
            // 2. 发生错误则强制启动 GB18030/GBK 字符集解码，降伏陈年老旧 Windows 字幕文件
            let gbkCFEncoding = CFStringEncodings.GB_18030_2000.rawValue
            let gbkEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(gbkCFEncoding)))
            return try String(contentsOf: url, encoding: gbkEncoding)
        }
    }
    
    /// 统一导入入口
    public static func importSubtitle(from url: URL) throws -> (format: SubtitleFormat, blocks: [SubtitleBlock]) {
        let pathExtension = url.pathExtension.lowercased()
        guard let format = SubtitleFormat(rawValue: pathExtension) else {
            throw NSError(domain: "FormatError", code: -2, userInfo: [NSLocalizedDescriptionKey: "暂不支持该多媒体文件后缀格式"])
        }
        
        let rawText = try loadRawText(from: url)
        guard let processor = processors[format] else { return (format, []) }
        
        return (format, processor.parse(text: rawText))
    }
    
    /// 自动判断纯文本/字幕内容并解析
    public static func parseAnyText(_ rawText: String) -> (hasTimeline: Bool, blocks: [SubtitleBlock]) {
        // 1. 判断是否为 ASS 字幕
        if rawText.contains("Dialogue:") {
            let blocks = ASSProcessor().parse(text: rawText)
            if !blocks.isEmpty {
                return (true, blocks)
            }
        }
        
        // 2. 判断是否为 SRT 字幕
        if rawText.contains("-->") {
            let blocks = SRTProcessor().parse(text: rawText)
            if !blocks.isEmpty {
                return (true, blocks)
            }
        }
        
        // 3. 判断是否为 LRC 歌词 (检测类似 [01:23.45] 的标签)
        if rawText.range(of: "\\[\\d{2,}:\\d{2}", options: .regularExpression) != nil {
            let blocks = LRCProcessor().parse(text: rawText)
            if !blocks.isEmpty {
                return (true, blocks)
            }
        }
        
        // 4. 降级为普通文本 (换行 txt)
        let lines = rawText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            
        let blocks = lines.map { line in
            SubtitleBlock(startTime: 0, endTime: 0, text: line)
        }
        return (false, blocks)
    }
}
