//
//  Centralized block and trim-handle geometry hit testing.
//

import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import GameController
#endif

extension SubtitleBlocksLayer {
    // MARK: Centralized hit testing and gestures

    func isPointInsideTimeline(_ location: CGPoint) -> Bool {
        location.x.isFinite
            && location.y.isFinite
            && location.y >= 0
            && location.y <= timelineHeight
    }

    struct BlockHit {
        let item: SubtitleItem
        let edge: TimelineInteractionLayer.Edge?
    }

    func hitTest(at location: CGPoint) -> BlockHit? {
        let blockHeight = SubtitleTimelineTrackMetrics.scaledBlockHeight(trackVerticalScale)
        #if os(iOS)
        let verticalTouchSlop: CGFloat = 10
        let horizontalTouchSlop: CGFloat = 22
        #else
        let verticalTouchSlop: CGFloat = 0
        let horizontalTouchSlop: CGFloat = 4
        #endif
        guard location.y >= activeTrackBlockY - verticalTouchSlop,
              location.y <= activeTrackBlockY + blockHeight + verticalTouchSlop else { return nil }
        let time = Double(location.x) / pixelsPerSecond
        let visualTolerance = Double(horizontalTouchSlop) / pixelsPerSecond
        let candidates = renderModel.visibleItems(
            in: max(0, time - visualTolerance)...(time + visualTolerance)
        )

        for item in candidates.reversed() {
            guard isInActiveGroup(item), isTimelineEditable(item), let start = item.startTime else { continue }
            var end = item.endTime ?? (start + 0.1)
            if item.id == renderModel.activeSlapSubtitleID {
                end = activeSlapEnd(for: item, at: .now)
            }
            let rect = CGRect(
                x: CGFloat(start * pixelsPerSecond),
                y: blockY(for: item),
                width: max(4, CGFloat((end - start) * pixelsPerSecond)),
                height: blockHeight
            )
            let canTrim = trimHandleItemIDs.contains(item.id)
            let edge: TimelineInteractionLayer.Edge?
            #if os(iOS)
            // Handles stay visually compact, while their finger targets extend
            // outside the block and 14 pt inward. Nearest-edge arbitration keeps
            // very short subtitles from always resolving to the left handle.
            let expandedRect = rect.insetBy(dx: -horizontalTouchSlop, dy: -verticalTouchSlop)
            guard expandedRect.contains(location) else { continue }
            let leftDistance = abs(location.x - rect.minX)
            let rightDistance = abs(location.x - rect.maxX)
            let isNearLeft = location.x >= rect.minX - horizontalTouchSlop
                && location.x <= rect.minX + 14
            let isNearRight = location.x >= rect.maxX - 14
                && location.x <= rect.maxX + horizontalTouchSlop
            if canTrim, isNearLeft || isNearRight {
                edge = leftDistance <= rightDistance ? .left : .right
            } else {
                edge = nil
            }
            guard edge != nil || rect.contains(location) else { continue }
            #else
            guard rect.contains(location) else { continue }
            let handleWidth = min(10, max(5, rect.width * 0.2))
            if canTrim, location.x <= rect.minX + handleWidth {
                edge = .left
            } else if canTrim, location.x >= rect.maxX - handleWidth {
                edge = .right
            } else {
                edge = nil
            }
            #endif
            return BlockHit(item: item, edge: edge)
        }
        return nil
    }

    func anyBlockHitTest(at location: CGPoint) -> SubtitleItem? {
        let blockHeight = SubtitleTimelineTrackMetrics.scaledBlockHeight(trackVerticalScale)
        #if os(iOS)
        let verticalTouchSlop: CGFloat = 10
        let horizontalTouchSlop: CGFloat = 22
        #else
        let verticalTouchSlop: CGFloat = 0
        let horizontalTouchSlop: CGFloat = 4
        #endif
        
        let time = Double(location.x) / pixelsPerSecond
        let visualTolerance = Double(horizontalTouchSlop) / pixelsPerSecond
        let candidates = renderModel.visibleItems(
            in: max(0, time - visualTolerance)...(time + visualTolerance)
        )

        for item in candidates.reversed() {
            guard let start = item.startTime else { continue }
            let end = item.endTime ?? (start + 0.1)
            let y = blockY(for: item)
            
            guard location.y >= y - verticalTouchSlop,
                  location.y <= y + blockHeight + verticalTouchSlop else { continue }
                  
            let rect = CGRect(
                x: CGFloat(start * pixelsPerSecond),
                y: y,
                width: max(4, CGFloat((end - start) * pixelsPerSecond)),
                height: blockHeight
            )
            
            #if os(iOS)
            let expandedRect = rect.insetBy(dx: -horizontalTouchSlop, dy: -verticalTouchSlop)
            if expandedRect.contains(location) {
                return item
            }
            #else
            if rect.contains(location) {
                return item
            }
            #endif
        }
        return nil
    }

    var blockDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in handleDragChanged(value) }
            .onEnded { value in handleDragEnded(value) }
    }

}
