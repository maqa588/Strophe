//
//  SubtitleItem.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import Foundation

struct SubtitleItem: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    var text: String
    var startTime: TimeInterval?
    var endTime: TimeInterval?
    var originalIndex: Int = 0
    
    var isTimed: Bool {
        startTime != nil
    }
}
