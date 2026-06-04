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
}
