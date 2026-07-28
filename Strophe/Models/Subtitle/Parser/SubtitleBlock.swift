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
    public var text: String            // 编辑器中显示的纯文本
    public var interchangeMetadata: SubtitleCueInterchangeMetadata?

    public init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        interchangeMetadata: SubtitleCueInterchangeMetadata? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.interchangeMetadata = interchangeMetadata
    }
}

// 支持的字幕格式枚举
public enum SubtitleFormat: String, CaseIterable, Codable, Sendable {
    case srt
    case lrc
    case ass
    case vtt
    
    public var fileExtension: String { self.rawValue }
}
