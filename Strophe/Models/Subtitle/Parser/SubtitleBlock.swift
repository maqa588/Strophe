//
//  SubtitleBlock.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import Foundation

public struct SubtitleBlock: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
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

public enum SubtitleFormat: String, CaseIterable, Codable, Sendable {
    case srt
    case lrc
    case ass
    case vtt

    public var fileExtension: String { rawValue }
}
