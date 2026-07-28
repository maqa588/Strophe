//
//  SubtitleItem.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import Foundation

struct SubtitleStyleOverrides: Codable, Sendable, Equatable {
    var textColorHex: String?
    var fontSize: Double?
    var isBold: Bool?
    var isItalic: Bool?
}

enum SubtitlePositionCoordinateSpace: String, Codable, Sendable, Equatable {
    /// Coordinates are expressed in source-video pixels.
    case canvas
    /// Coordinates are normalized to the 0...1 range.
    case normalized
}

struct SubtitlePositionOverride: Codable, Sendable, Equatable {
    var x: Double?
    var y: Double?
    /// Backward-compatible anchor field. Values use SubtitleStyle.Alignment raw values.
    var alignmentRaw: String?
    var coordinateSpace: SubtitlePositionCoordinateSpace?
}

enum SubtitleCollisionMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Earlier/lower-track subtitles retain the base position and later tracks
    /// are moved toward the center of the frame.
    case normal
    /// Later/higher-track subtitles retain the base position and earlier tracks
    /// are moved toward the center of the frame.
    case reverse
    /// Preserve every cue's authored position even when rectangles overlap.
    case disabled
}

struct SubtitleItem: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var text: String
    var startTime: TimeInterval?
    var endTime: TimeInterval?
    var originalIndex: Int
    
    // Style & bilingual extensibility
    var groupID: UUID?
    var trackIndex: Int
    /// Compositing layer. Higher layers are drawn later and therefore appear on top.
    var layer: Int
    var styleID: UUID?
    var styleOverrides: SubtitleStyleOverrides?
    var positionOverride: SubtitlePositionOverride?
    var parentItemID: UUID?
    var languageCode: String?
    var bilingualPairID: UUID?
    var isHidden: Bool
    var isLocked: Bool
    /// Lossless source-format information (ASS tags/style fields, VTT settings,
    /// original cue identifiers, and similar data).
    var interchangeMetadata: SubtitleCueInterchangeMetadata?
    
    init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        originalIndex: Int = 0,
        groupID: UUID? = nil,
        trackIndex: Int = 0,
        layer: Int = 0,
        styleID: UUID? = nil,
        styleOverrides: SubtitleStyleOverrides? = nil,
        positionOverride: SubtitlePositionOverride? = nil,
        parentItemID: UUID? = nil,
        languageCode: String? = nil,
        bilingualPairID: UUID? = nil,
        isHidden: Bool = false,
        isLocked: Bool = false,
        interchangeMetadata: SubtitleCueInterchangeMetadata? = nil
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.originalIndex = originalIndex
        self.groupID = groupID
        self.trackIndex = trackIndex
        self.layer = layer
        self.styleID = styleID
        self.styleOverrides = styleOverrides
        self.positionOverride = positionOverride
        self.parentItemID = parentItemID
        self.languageCode = languageCode
        self.bilingualPairID = bilingualPairID
        self.isHidden = isHidden
        self.isLocked = isLocked
        self.interchangeMetadata = interchangeMetadata
    }
    
    var isTimed: Bool {
        startTime != nil
    }

    var hasIndependentPresentation: Bool {
        styleID != nil || styleOverrides != nil || positionOverride != nil
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case startTime
        case endTime
        case originalIndex
        case groupID
        case trackIndex
        case layer
        case styleID
        case styleOverrides
        case positionOverride
        case parentItemID
        case languageCode
        case bilingualPairID
        case isHidden
        case isLocked
        case interchangeMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        startTime = try container.decodeIfPresent(TimeInterval.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(TimeInterval.self, forKey: .endTime)
        originalIndex = try container.decodeIfPresent(Int.self, forKey: .originalIndex) ?? 0
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        trackIndex = try container.decodeIfPresent(Int.self, forKey: .trackIndex) ?? 0
        layer = try container.decodeIfPresent(Int.self, forKey: .layer) ?? 0
        styleID = try container.decodeIfPresent(UUID.self, forKey: .styleID)
        styleOverrides = try container.decodeIfPresent(SubtitleStyleOverrides.self, forKey: .styleOverrides)
        positionOverride = try container.decodeIfPresent(SubtitlePositionOverride.self, forKey: .positionOverride)
        parentItemID = try container.decodeIfPresent(UUID.self, forKey: .parentItemID)
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        bilingualPairID = try container.decodeIfPresent(UUID.self, forKey: .bilingualPairID)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        interchangeMetadata = try container.decodeIfPresent(
            SubtitleCueInterchangeMetadata.self,
            forKey: .interchangeMetadata
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(startTime, forKey: .startTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
        try container.encode(originalIndex, forKey: .originalIndex)
        try container.encodeIfPresent(groupID, forKey: .groupID)
        try container.encode(trackIndex, forKey: .trackIndex)
        try container.encode(layer, forKey: .layer)
        try container.encodeIfPresent(styleID, forKey: .styleID)
        try container.encodeIfPresent(styleOverrides, forKey: .styleOverrides)
        try container.encodeIfPresent(positionOverride, forKey: .positionOverride)
        try container.encodeIfPresent(parentItemID, forKey: .parentItemID)
        try container.encodeIfPresent(languageCode, forKey: .languageCode)
        try container.encodeIfPresent(bilingualPairID, forKey: .bilingualPairID)
        try container.encode(isHidden, forKey: .isHidden)
        try container.encode(isLocked, forKey: .isLocked)
        try container.encodeIfPresent(interchangeMetadata, forKey: .interchangeMetadata)
    }
}
