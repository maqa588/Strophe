//
//  SubtitleProject+Overlap.swift
//  Strophe
//
//  Overlap detection and computation
//

import Foundation

extension SubtitleProject {
    struct OverlapInterval: Hashable {
        public let start: TimeInterval
        public let end: TimeInterval
    }
    
    func isItemOverlapping(id: UUID) -> Bool {
        return timelineIndex.overlappingItemIDs.contains(id)
    }
    
    var overlappingIntervals: [OverlapInterval] {
        return timelineIndex.overlappingIntervals
    }
}
