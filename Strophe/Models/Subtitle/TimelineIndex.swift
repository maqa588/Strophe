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
    private var maxEndPrefixByStartTime: [Double] = []
    private var itemByID: [UUID: SubtitleItem] = [:]
    
    func rebuild(with items: [SubtitleItem]) {
        self.itemIndexByID = [:]
        self.itemByID = [:]
        for (i, item) in items.enumerated() {
            self.itemIndexByID[item.id] = i
            self.itemByID[item.id] = item
        }
        
        let timedItems = items.filter { $0.startTime != nil }
        self.itemsByStartTime = timedItems.sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
        self.maxEndPrefixByStartTime = []
        self.maxEndPrefixByStartTime.reserveCapacity(itemsByStartTime.count)
        var maxEndSoFar = -Double.infinity
        for item in itemsByStartTime {
            let start = item.startTime ?? 0
            let end = item.endTime ?? (start + 0.1)
            maxEndSoFar = max(maxEndSoFar, end)
            maxEndPrefixByStartTime.append(maxEndSoFar)
        }
        
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
        guard !itemsByStartTime.isEmpty else { return results }

        let startIndex = firstIndexWithStart(greaterThanOrEqualTo: range.lowerBound)
        var scanIndex = startIndex
        while scanIndex > 0, maxEndPrefixByStartTime[scanIndex - 1] >= range.lowerBound {
            let previousIndex = scanIndex - 1
            let item = itemsByStartTime[previousIndex]
            let start = item.startTime ?? 0
            let end = item.endTime ?? (start + 0.1)
            if end >= range.lowerBound {
                results.append(item)
            }
            scanIndex = previousIndex
        }
        results.reverse()

        for item in itemsByStartTime[startIndex...] {
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
        let ignoredStart: Double?
        let ignoredEnd: Double?
        if let ignoredItemID,
           let ignoredItem = itemByID[ignoredItemID] {
            ignoredStart = ignoredItem.startTime
            ignoredEnd = ignoredItem.endTime
        } else {
            ignoredStart = nil
            ignoredEnd = nil
        }

        guard !sortedSnapEdges.isEmpty else { return nil }
        let insertionIndex = firstSnapEdgeIndex(greaterThanOrEqualTo: time)

        var left = insertionIndex - 1
        var right = insertionIndex
        var best: Double?
        var bestDistance = Double.infinity

        while left >= 0 || right < sortedSnapEdges.count {
            var advanced = false
            if right < sortedSnapEdges.count {
                let candidate = sortedSnapEdges[right]
                let distance = abs(candidate - time)
                if distance > bestDistance { break }
                if !isIgnoredSnapEdge(candidate, ignoredStart: ignoredStart, ignoredEnd: ignoredEnd) {
                    best = candidate
                    bestDistance = distance
                }
                right += 1
                advanced = true
            }

            if left >= 0 {
                let candidate = sortedSnapEdges[left]
                let distance = abs(candidate - time)
                if distance <= bestDistance,
                   !isIgnoredSnapEdge(candidate, ignoredStart: ignoredStart, ignoredEnd: ignoredEnd) {
                    best = candidate
                    bestDistance = distance
                }
                left -= 1
                advanced = true
            }

            if best != nil { break }
            if !advanced { break }
        }

        return best
    }

    private func firstIndexWithStart(greaterThanOrEqualTo time: Double) -> Int {
        var low = 0
        var high = itemsByStartTime.count

        while low < high {
            let mid = low + (high - low) / 2
            let start = itemsByStartTime[mid].startTime ?? .infinity
            if start < time {
                low = mid + 1
            } else {
                high = mid
            }
        }

        return low
    }

    private func firstSnapEdgeIndex(greaterThanOrEqualTo time: Double) -> Int {
        var low = 0
        var high = sortedSnapEdges.count

        while low < high {
            let mid = low + (high - low) / 2
            if sortedSnapEdges[mid] < time {
                low = mid + 1
            } else {
                high = mid
            }
        }

        return low
    }

    private func isIgnoredSnapEdge(_ edge: Double, ignoredStart: Double?, ignoredEnd: Double?) -> Bool {
        edge == ignoredStart || edge == ignoredEnd
    }
}
