//
//  StropheProjectData.swift
//  Strophe
//

import Foundation
import CoreGraphics

struct StropheProjectData: Sendable {
    let version: Int
    let metadata: StropheMetadata
    let media: StropheMedia?
    let items: [SubtitleItem]
    
    struct StropheMetadata: Sendable, Codable {
        var videoFrameRate: Double
        var videoSize: StropheVideoSize?
        var isAudioOnly: Bool
        var showSoftSubtitles: Bool
        var editingModeRaw: String
        var currentTime: Double
        var createdAt: Date
        var modifiedAt: Date
    }
    
    struct StropheVideoSize: Sendable, Codable {
        let width: Double
        let height: Double
    }
    
    struct StropheMedia: Sendable, Codable {
        var originalURL: URL?
        var bookmark: Data?
    }
}

nonisolated extension StropheProjectData: Codable {}

extension StropheProjectData.StropheMetadata {
    var editingMode: TimelineEditingMode {
        TimelineEditingMode(rawValue: editingModeRaw) ?? .selection
    }
}

extension TimelineEditingMode {
    var rawValue: String {
        switch self {
        case .selection: return "selection"
        case .creation:  return "creation"
        }
    }
}
