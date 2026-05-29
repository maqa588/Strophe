//
//  StropheProjectData.swift
//  Strophe
//

import Foundation
import CoreGraphics

struct StropheTrack: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var language: String?  // "zh-Hans", "en", "ja", etc.
    var isEnabled: Bool
    var items: [SubtitleItem]
    
    // Extensibility fields for bilingual/translation bindings
    var parentTrackID: UUID? // Reference to the primary track if this is a translation track
    var trackType: TrackType
    
    enum TrackType: String, Codable, Sendable {
        case primary
        case translation
        case auxiliary
    }
}

struct SubtitleStyle: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    var name: String
    
    // Typography
    var fontName: String?
    var fontSize: Double
    var textColorHex: String // e.g., "#FFFFFFFF" (RGBA Hex)
    var isBold: Bool
    var isItalic: Bool
    var isUnderline: Bool
    
    // Layout & Alignment
    var alignment: Alignment
    var marginL: Double
    var marginR: Double
    var marginV: Double
    
    // Style Decorators
    var outlineColorHex: String?
    var outlineWidth: Double?
    var shadowColorHex: String?
    var shadowWidth: Double?
    
    // Background box
    var backgroundColorHex: String?
    var backgroundAlpha: Double? // 0.0 to 1.0
    
    enum Alignment: String, Codable, Sendable {
        case topLeft, topCenter, topRight
        case middleLeft, middleCenter, middleRight
        case bottomLeft, bottomCenter, bottomRight
    }
}

nonisolated struct StropheProjectData: Sendable, Codable {
    let version: Int
    let metadata: StropheMetadata
    let media: StropheMedia?
    var tracks: [StropheTrack]
    var styles: [SubtitleStyle]
    
    /// For backward compatibility with interfaces expecting a flat items array.
    var items: [SubtitleItem] {
        tracks.first?.items ?? []
    }
    
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
