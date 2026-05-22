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

struct SubtitleItem: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var text: String
    var startTime: TimeInterval?
    var endTime: TimeInterval?
    var originalIndex: Int
    
    // Style & bilingual extensibility
    var styleID: UUID?
    var styleOverrides: SubtitleStyleOverrides?
    var parentItemID: UUID?
    
    init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        originalIndex: Int = 0,
        styleID: UUID? = nil,
        styleOverrides: SubtitleStyleOverrides? = nil,
        parentItemID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.originalIndex = originalIndex
        self.styleID = styleID
        self.styleOverrides = styleOverrides
        self.parentItemID = parentItemID
    }
    
    var isTimed: Bool {
        startTime != nil
    }
}
