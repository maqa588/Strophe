//
//  SubtitleBlock.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import Foundation

public struct SubtitleBlock: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var startTime: TimeInterval // 统一转化为绝对秒数，例如 73.45 秒
    public var endTime: TimeInterval   // 绝对秒数
    public var text: String            // 过滤掉所有特效标签后的纯文本

    public init(id: UUID = UUID(), startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

// 支持的字幕格式枚举
public enum SubtitleFormat: String, CaseIterable, Sendable {
    case srt
    case lrc
    case ass
    
    public var fileExtension: String { self.rawValue }
}
