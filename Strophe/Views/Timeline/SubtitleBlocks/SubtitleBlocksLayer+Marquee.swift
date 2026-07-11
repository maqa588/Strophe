//
//  Two-dimensional multi-track marquee selection and edge scrolling.
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
    // MARK: Marquee auto-scroll

    func beginMarquee(at location: CGPoint) {
        guard isPointInsideTimeline(location) else {
            dragMode = .ignored
            return
        }
        marqueeStart = location
        marqueeCurrent = location
        dragMode = .marquee
        project.selectedIDs.removeAll()
        project.isSubtitleMultiSelecting = true
        ensureMarqueeAutoScrollTask()
    }

    func updateSelectionForMarquee() {
        guard let start = marqueeStart, let current = marqueeCurrent else { return }
        let selectionRect = SubtitleMarqueeSelectionGeometry.normalizedRect(from: start, to: current)
        let minTime = max(0, Double(selectionRect.minX) / pixelsPerSecond)
        let maxTime = max(minTime, Double(selectionRect.maxX) / pixelsPerSecond)
        let blockHeight = SubtitleTimelineTrackMetrics.scaledBlockHeight(trackVerticalScale)

        let newSelection = Set(
            renderModel.visibleItems(in: minTime...maxTime)
                .filter { item in
                    guard let startTime = item.startTime,
                          renderModel.group(for: item)?.isOverlayEnabled == true else { return false }
                    let endTime = item.endTime ?? (startTime + 0.1)
                    let itemRect = CGRect(
                        x: CGFloat(startTime * pixelsPerSecond),
                        y: blockY(for: item),
                        width: max(4, CGFloat((endTime - startTime) * pixelsPerSecond)),
                        height: blockHeight
                    )
                    return selectionRect.intersects(itemRect)
                }
                .map(\.id)
        )
        if project.selectedIDs != newSelection {
            project.selectedIDs = newSelection
        }
        let isMultiSelecting = !newSelection.isEmpty
        if project.isSubtitleMultiSelecting != isMultiSelecting {
            project.isSubtitleMultiSelecting = isMultiSelecting
        }
    }

    func ensureMarqueeAutoScrollTask() {
        guard marqueeAutoScrollTask == nil else { return }
        marqueeAutoScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                performMarqueeAutoScrollStep()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func stopMarqueeAutoScroll() {
        marqueeAutoScrollTask?.cancel()
        marqueeAutoScrollTask = nil
    }

    func performMarqueeAutoScrollStep() {
        guard marqueeStart != nil, let current = marqueeCurrent else { return }
        guard pixelsPerSecond.isFinite, pixelsPerSecond > 0 else { return }
        guard viewWidth.isFinite, viewWidth > 0 else { return }

        let duration = workspaceDuration.isFinite ? max(0, workspaceDuration) : 0
        let visibleDuration = Double(viewWidth) / pixelsPerSecond
        let maxStartTime = max(0, duration - visibleDuration)
        guard maxStartTime > 0 else { return }

        let visibleStartX = CGFloat(scrollPageStartTime * pixelsPerSecond)
        let visibleEndX = visibleStartX + viewWidth
        let leftDistance = current.x - visibleStartX
        let rightDistance = visibleEndX - current.x
        let direction: CGFloat
        let edgeOverlap: CGFloat

        if leftDistance < marqueeAutoScrollEdgeInset {
            direction = -1
            edgeOverlap = marqueeAutoScrollEdgeInset - max(0, leftDistance)
        } else if rightDistance < marqueeAutoScrollEdgeInset {
            direction = 1
            edgeOverlap = marqueeAutoScrollEdgeInset - max(0, rightDistance)
        } else {
            return
        }

        let strength = min(1, max(0, edgeOverlap / marqueeAutoScrollEdgeInset))
        let speed = marqueeAutoScrollMaxSpeed * max(0.18, strength * strength)
        let deltaPixels = direction * speed * CGFloat(marqueeAutoScrollFrameInterval)
        let oldStart = scrollPageStartTime.clampedFinite(to: 0...maxStartTime)
        let newStart = (oldStart + Double(deltaPixels) / pixelsPerSecond).clampedFinite(to: 0...maxStartTime)
        let actualDeltaPixels = CGFloat((newStart - oldStart) * pixelsPerSecond)
        guard abs(actualDeltaPixels) > 0.001 else { return }

        scrollPageStartTime = newStart
        marqueeCurrent = CGPoint(x: current.x + actualDeltaPixels, y: current.y)
        updateSelectionForMarquee()
    }

}
