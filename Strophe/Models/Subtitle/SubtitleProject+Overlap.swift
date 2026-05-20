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
        guard let item = items.first(where: { $0.id == id }),
              let start = item.startTime,
              let end = item.endTime else { return false }
        
        for other in items {
            guard other.id != id,
                  let oStart = other.startTime,
                  let oEnd = other.endTime else { continue }
            
            if start < oEnd && oStart < end {
                return true
            }
        }
        return false
    }
    
    var overlappingIntervals: [OverlapInterval] {
        var intervals: [OverlapInterval] = []
        let timed = items.filter { $0.startTime != nil && $0.endTime != nil }
        guard timed.count > 1 else { return [] }
        
        for i in 0..<timed.count {
            for j in (i+1)..<timed.count {
                let a = timed[i]
                let b = timed[j]
                let startA = a.startTime!
                let endA = a.endTime!
                let startB = b.startTime!
                let endB = b.endTime!
                
                let overlapStart = max(startA, startB)
                let overlapEnd = min(endA, endB)
                
                if overlapStart < overlapEnd {
                    intervals.append(OverlapInterval(start: overlapStart, end: overlapEnd))
                }
            }
        }
        
        return mergeIntervals(intervals)
    }
    
    private func mergeIntervals(_ list: [OverlapInterval]) -> [OverlapInterval] {
        guard list.count > 1 else { return list }
        let sorted = list.sorted { $0.start < $1.start }
        var merged: [OverlapInterval] = []
        var current = sorted[0]
        
        for next in sorted[1...] {
            if next.start <= current.end {
                current = OverlapInterval(start: current.start, end: max(current.end, next.end))
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }
}
