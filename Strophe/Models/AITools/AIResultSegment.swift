//
//  AIResultSegment.swift
//  Strophe
//
//  Created by Codex on 2026/06/04.
//

import Foundation

nonisolated struct AIResultSegment: Sendable, Codable {
    let text: String
    let startTime: Double
    let endTime: Double
    /// Word/grapheme timing survives segmentation so downstream editors can
    /// build karaoke without running ForcedAligner a second time.
    let words: [SubtitleWordTiming]

    init(
        text: String,
        startTime: Double,
        endTime: Double,
        words: [SubtitleWordTiming] = []
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.words = words
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case startTime
        case endTime
        case words
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        startTime = try container.decode(Double.self, forKey: .startTime)
        endTime = try container.decode(Double.self, forKey: .endTime)
        words = try container.decodeIfPresent(
            [SubtitleWordTiming].self,
            forKey: .words
        ) ?? []
    }
}
