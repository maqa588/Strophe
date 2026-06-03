//
//  TimelineIndex.swift
//  Strophe
//
//  Created by Antigravity on 2026/06/03.
//

import Foundation

class TimelineIndex {
    private(set) var itemsByStartTime: [SubtitleItem] = []
    private(set) var sortedSnapEdges: [Double] = []
    private(set) var overlappingIntervals: [SubtitleProject.OverlapInterval] = []
    private(set) var overlappingItemIDs: Set<UUID> = []
    private(set) var itemIndexByID: [UUID: Int] = [:]
    
    func rebuild(with items: [SubtitleItem]) {
        self.itemIndexByID = [:]
        for (i, item) in items.enumerated() {
            self.itemIndexByID[item.id] = i
        }
        
        let timedItems = items.filter { $0.startTime != nil }
        self.itemsByStartTime = timedItems.sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
        
        var edges = Set<Double>()
        for item in timedItems {
            if let s = item.startTime { edges.insert(s) }
            if let e = item.endTime { edges.insert(e) }
        }
        self.sortedSnapEdges = Array(edges).sorted()
        
        self.overlappingIntervals = []
        self.overlappingItemIDs = []
        
        let grouped = Dictionary(grouping: timedItems, by: { $0.groupID })
        for (_, groupItems) in grouped {
            let sorted = groupItems.sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
            guard sorted.count > 1 else { continue }
            
            var maxEndSoFar: Double = -1
            var maxEndItem: SubtitleItem? = nil
            var intervals: [SubtitleProject.OverlapInterval] = []
            
            for item in sorted {
                let start = item.startTime!
                let end = item.endTime ?? (start + 0.1)
                
                if start < maxEndSoFar {
                    overlappingItemIDs.insert(item.id)
                    if let maxEItem = maxEndItem {
                        overlappingItemIDs.insert(maxEItem.id)
                    }
                    
                    let overlapStart = start
                    let overlapEnd = min(end, maxEndSoFar)
                    if overlapStart < overlapEnd {
                        intervals.append(SubtitleProject.OverlapInterval(start: overlapStart, end: overlapEnd))
                    }
                    
                    if end > maxEndSoFar {
                        maxEndSoFar = end
                        maxEndItem = item
                    }
                } else {
                    maxEndSoFar = end
                    maxEndItem = item
                }
            }
            self.overlappingIntervals.append(contentsOf: intervals)
        }
        self.overlappingIntervals = mergeIntervals(self.overlappingIntervals)
    }
    
    private func mergeIntervals(_ list: [SubtitleProject.OverlapInterval]) -> [SubtitleProject.OverlapInterval] {
        guard list.count > 1 else { return list }
        let sorted = list.sorted { $0.start < $1.start }
        var merged: [SubtitleProject.OverlapInterval] = []
        var current = sorted[0]
        
        for next in sorted[1...] {
            if next.start <= current.end {
                current = SubtitleProject.OverlapInterval(start: current.start, end: max(current.end, next.end))
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }
    
    func visibleItems(in range: ClosedRange<Double>) -> [SubtitleItem] {
        var results = [SubtitleItem]()
        for item in itemsByStartTime {
            guard let start = item.startTime else { continue }
            if start > range.upperBound {
                break
            }
            let end = item.endTime ?? (start + 0.1)
            if end >= range.lowerBound {
                results.append(item)
            }
        }
        return results
    }
    
    func nearestSnapPoint(to time: Double, ignoring ignoredItemID: UUID? = nil) -> Double? {
        let edges: [Double]
        if let ignoredItemID,
           let ignoredItem = itemsByStartTime.first(where: { $0.id == ignoredItemID }) {
            edges = sortedSnapEdges.filter { edge in
                edge != ignoredItem.startTime && edge != ignoredItem.endTime
            }
        } else {
            edges = sortedSnapEdges
        }

        guard !edges.isEmpty else { return nil }
        var low = 0
        var high = edges.count - 1
        
        while low < high {
            let mid = low + (high - low) / 2
            if edges[mid] < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        
        let candidate1 = edges[low]
        if low > 0 {
            let candidate2 = edges[low - 1]
            if abs(candidate2 - time) < abs(candidate1 - time) {
                return candidate2
            }
        }
        return candidate1
    }
}
