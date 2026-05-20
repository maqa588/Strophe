//
//  SubtitleProjectData.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import Foundation

struct SubtitleProjectData: Sendable {
    let items: [SubtitleItem]
    let videoURL: URL?
}

nonisolated extension SubtitleProjectData: Codable {}
