//
//  Shared block move, trim, snapping, and track-transfer behavior.
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
    func liftProgress(from startDate: Date, at date: Date) -> CGFloat {
        let duration = 0.30
        let t = min(1, max(0, date.timeIntervalSince(startDate) / duration))
        guard t < 1 else { return 1 }
        // easeOutBack: quick initial lift with a small physical overshoot.
        let c1 = 1.70158
        let c3 = c1 + 1
        let shifted = t - 1
        return CGFloat(1 + c3 * shifted * shifted * shifted + c1 * shifted * shifted)
    }

    func handleDragChanged(_ value: DragGesture.Value) {
        guard renderModel.editingMode == .selection, !isLiftDragging else { return }

        if case .none = dragMode {
            beginDrag(at: value.startLocation)
        }

        #if os(iOS)
        if dragAxisIntent == .undecided {
            let horizontal = abs(value.translation.width)
            let vertical = abs(value.translation.height)
            guard max(horizontal, vertical) >= 6 else { return }
            dragAxisIntent = horizontal >= vertical ? .horizontal : .vertical
        }
        guard dragAxisIntent == .horizontal else {
            dragMode = .ignored
            activeDragDelta = 0
            activeDragVerticalDelta = 0
            return
        }
        #endif

        switch dragMode {
        case .move(_, let initialStart, let initialEnd):
            let delta = Double(value.translation.width) / pixelsPerSecond
            activeDragDelta = snappedDelta(
                proposals: [
                    DragSnapProposal(anchor: .start, initialTime: initialStart, proposedTime: initialStart + delta),
                    DragSnapProposal(anchor: .end, initialTime: initialEnd, proposedTime: initialEnd + delta)
                ],
                rawDelta: delta,
                ignoring: movingItemIDs
            )
            #if os(macOS)
            updateVerticalTrackDrag(translation: value.translation.height)
            #endif

        case .leftEdge(let itemID, let initialStart, _):
            let delta = Double(value.translation.width) / pixelsPerSecond
            activeDragDelta = snappedDelta(
                proposals: [DragSnapProposal(
                    anchor: .start,
                    initialTime: initialStart,
                    proposedTime: initialStart + delta
                )],
                rawDelta: delta,
                ignoring: [itemID]
            )

        case .rightEdge(let itemID, _, let initialEnd):
            let delta = Double(value.translation.width) / pixelsPerSecond
            activeDragDelta = snappedDelta(
                proposals: [DragSnapProposal(
                    anchor: .end,
                    initialTime: initialEnd,
                    proposedTime: initialEnd + delta
                )],
                rawDelta: delta,
                ignoring: [itemID]
            )

        case .marquee:
            if marqueeCurrent != value.location {
                marqueeCurrent = value.location
            }
            updateSelectionForMarquee()
            ensureMarqueeAutoScrollTask()

        case .ignored, .none:
            break
        }
    }

    func beginDrag(at location: CGPoint) {
        if let hit = hitTest(at: location) {
            let item = hit.item
            guard isTimelineEditable(item) else {
                dragMode = .ignored
                return
            }

            if !project.selectedIDs.contains(item.id) {
                project.selectedIDs = [item.id]
                project.isSubtitleMultiSelecting = false
            }
            contextItemID = item.id

            guard let start = item.startTime else {
                dragMode = .ignored
                return
            }
            let end = item.endTime ?? (start + 0.1)
            let dragEdge = hit.edge
            activeDragItemID = item.id
            activeDragEdge = dragEdge
            dragSnapGroupID = renderModel.group(for: item)?.id
            dragTargetGroupID = dragSnapGroupID

            if let edge = dragEdge {
                dragMode = edge == .left
                    ? .leftEdge(itemID: item.id, initialStart: start, initialEnd: end)
                    : .rightEdge(itemID: item.id, initialStart: start, initialEnd: end)
            } else {
                movingItemIDs = Set(project.items.lazy.filter {
                    project.selectedIDs.contains($0.id) && isTimelineEditable($0)
                }.map(\.id))
                let movingItems = project.items.filter { movingItemIDs.contains($0.id) }
                let selectionStart = movingItems.compactMap(\.startTime).min() ?? start
                let selectionEnd = movingItems.compactMap(\.endTime).max() ?? end
                dragMode = .move(
                    itemID: item.id,
                    initialStart: selectionStart,
                    initialEnd: selectionEnd
                )
                #if os(macOS)
                triggerLiftHapticFeedback()
                #endif
            }
            return
        } else if let hitItem = anyBlockHitTest(at: location) {
            if let groupID = renderModel.group(for: hitItem)?.id,
               groupID != renderModel.activeGroupID {
                StyleAndGroupStore.shared.setActiveGroup(groupID)
                beginDrag(at: location)
            } else {
                dragMode = .ignored
            }
            return
        }

        #if os(macOS)
        guard isPointInsideTimeline(location) else {
            dragMode = .ignored
            return
        }
        beginMarquee(at: location)
        #else
        dragMode = .ignored
        #endif
    }

    func handleDragEnded(_ value: DragGesture.Value) {
        defer { resetDragState() }

        switch dragMode {
        case .leftEdge, .rightEdge, .move:
            commitActiveBlockEdit()
        case .marquee:
            marqueeCurrent = value.location
            updateSelectionForMarquee()
        case .ignored, .none:
            break
        }
    }

    func commitActiveBlockEdit() {
        switch dragMode {
        case .leftEdge(let itemID, let initialStart, let initialEnd):
            project.updateSubtitleTime(
                id: itemID,
                newStartTime: initialStart + activeDragDelta,
                newEndTime: initialEnd
            )
        case .rightEdge(let itemID, let initialStart, let initialEnd):
            project.updateSubtitleTime(
                id: itemID,
                newStartTime: initialStart,
                newEndTime: initialEnd + activeDragDelta
            )
        case .move:
            commitActiveMove()
        case .marquee, .ignored, .none:
            break
        }
    }

    func resetDragState() {
        stopMarqueeAutoScroll()
        dragMode = .none
        activeDragItemID = nil
        activeDragEdge = nil
        activeDragDelta = 0
        activeDragVerticalDelta = 0
        movingItemIDs.removeAll()
        dragSnapGroupID = nil
        dragSnapLock = nil
        dragTargetGroupID = nil
        dragAxisIntent = .undecided
        isLiftDragging = false
        liftAnimationStartDate = nil
        directTouchMode = .none
        marqueeStart = nil
        marqueeCurrent = nil
    }

    func updateVerticalTrackDrag(translation: CGFloat) {
        activeDragVerticalDelta = abs(translation) < 6 ? 0 : translation
        guard let activeDragItemID,
              let item = renderModel.item(id: activeDragItemID) else {
            dragTargetGroupID = nil
            return
        }
        let centerY = blockY(for: item)
            + SubtitleTimelineTrackMetrics.scaledBlockHeight(trackVerticalScale) * 0.5
            + activeDragVerticalDelta
        let newTargetGroupID = trackGroup(at: centerY)?.id
        if newTargetGroupID != dragTargetGroupID {
            dragTargetGroupID = newTargetGroupID
            if newTargetGroupID != nil { triggerHapticFeedback() }
        }
    }

    func trackGroup(at y: CGFloat) -> SubGroupItem? {
        let rawIndex = SubtitleTimelineTrackMetrics.trackIndex(
            at: y,
            scale: trackVerticalScale,
            offset: trackVerticalOffset
        )
        guard trackGroups.indices.contains(rawIndex) else { return nil }
        let group = trackGroups[rawIndex]
        return group.isLocked ? nil : group
    }

    func commitActiveMove() {
        guard !movingItemIDs.isEmpty else { return }
        if let dragTargetGroupID, dragTargetGroupID != dragSnapGroupID {
            project.moveBlocks(
                ids: movingItemIDs,
                by: activeDragDelta,
                toGroup: dragTargetGroupID
            )
            StyleAndGroupStore.shared.setActiveGroup(dragTargetGroupID)
        } else if abs(activeDragDelta) > 0.000_001 {
            project.moveBlocks(ids: movingItemIDs, by: activeDragDelta)
        }
    }

    func snappedDelta(
        proposals: [DragSnapProposal],
        rawDelta: Double,
        ignoring ignoredItemIDs: Set<UUID>
    ) -> Double {
        let acquireThreshold = 7.0 / pixelsPerSecond
        let releaseThreshold = 14.0 / pixelsPerSecond

        if let locked = dragSnapLock,
           let proposal = proposals.first(where: { $0.anchor == locked.anchor }),
           abs(proposal.proposedTime - locked.targetTime) <= releaseThreshold {
            return locked.targetTime - proposal.initialTime
        }

        let previousLock = dragSnapLock
        dragSnapLock = nil
        var bestProposal: DragSnapProposal?
        var bestTarget: Double?
        var bestDistance = Double.infinity

        for proposal in proposals {
            let playheadDistance = abs(project.currentTime - proposal.proposedTime)
            if playheadDistance <= acquireThreshold, playheadDistance < bestDistance {
                bestProposal = proposal
                bestTarget = project.currentTime
                bestDistance = playheadDistance
            }

            if let blockTarget = renderModel.nearestSnapPoint(
                to: proposal.proposedTime,
                groupID: dragSnapGroupID,
                ignoring: ignoredItemIDs
            ) {
                let distance = abs(blockTarget - proposal.proposedTime)
                if distance <= acquireThreshold, distance < bestDistance {
                    bestProposal = proposal
                    bestTarget = blockTarget
                    bestDistance = distance
                }
            }
        }

        guard let bestProposal, let bestTarget else { return rawDelta }
        let newLock = DragSnapLock(anchor: bestProposal.anchor, targetTime: bestTarget)
        dragSnapLock = newLock
        if previousLock != newLock { triggerHapticFeedback() }
        return bestTarget - bestProposal.initialTime
    }

    func handleTap(at location: CGPoint) {
        guard renderModel.editingMode == .selection else { return }
        var hit = hitTest(at: location)
        if hit == nil, let hitItem = anyBlockHitTest(at: location) {
            if let groupID = renderModel.group(for: hitItem)?.id {
                StyleAndGroupStore.shared.setActiveGroup(groupID)
                hit = hitTest(at: location)
            }
        }
        guard let item = hit?.item else {
            if !project.selectedIDs.isEmpty { project.selectedIDs.removeAll() }
            if project.isSubtitleMultiSelecting { project.isSubtitleMultiSelecting = false }
            contextItemID = nil
            return
        }

        contextItemID = item.id
        if commandKeyIsPressed, isInActiveGroup(item) {
            if project.selectedIDs.contains(item.id) {
                project.selectedIDs.remove(item.id)
            } else {
                project.selectedIDs.insert(item.id)
            }
            project.isSubtitleMultiSelecting = project.selectedIDs.count > 1
        } else if project.isSubtitleMultiSelecting, isInActiveGroup(item) {
            if project.selectedIDs.contains(item.id) {
                project.selectedIDs.remove(item.id)
            } else {
                project.selectedIDs.insert(item.id)
            }
            project.isSubtitleMultiSelecting = !project.selectedIDs.isEmpty
        } else {
            project.selectedIDs = [item.id]
            project.isSubtitleMultiSelecting = false
        }
    }

    func handleDoubleTap(at location: CGPoint) {
        var hit = hitTest(at: location)
        if hit == nil, let hitItem = anyBlockHitTest(at: location) {
            if let groupID = renderModel.group(for: hitItem)?.id {
                StyleAndGroupStore.shared.setActiveGroup(groupID)
                hit = hitTest(at: location)
            }
        }
        guard let item = hit?.item, !isLocked(item) else { return }
        contextItemID = item.id
        beginEditingText(item)
    }

    #if os(iOS)
    func handleMobileDoubleTap(at location: CGPoint) {
        var hit = hitTest(at: location)
        if hit == nil, let hitItem = anyBlockHitTest(at: location) {
            if let groupID = renderModel.group(for: hitItem)?.id {
                StyleAndGroupStore.shared.setActiveGroup(groupID)
                hit = hitTest(at: location)
            }
        }
        guard let item = hit?.item else { return }
        contextItemID = item.id
        if !project.selectedIDs.contains(item.id) {
            project.selectedIDs = [item.id]
            project.isSubtitleMultiSelecting = false
        }
        isShowingMobileBlockActions = true
    }
    #endif

    var commandKeyIsPressed: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.command)
        #elseif os(iOS)
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else { return false }
        return keyboard.button(forKeyCode: .leftGUI)?.isPressed == true
            || keyboard.button(forKeyCode: .rightGUI)?.isPressed == true
        #else
        false
        #endif
    }

    func isInActiveGroup(_ item: SubtitleItem) -> Bool {
        renderModel.group(for: item)?.id == renderModel.activeGroupID
    }

    func isLocked(_ item: SubtitleItem) -> Bool {
        item.isLocked || renderModel.group(for: item)?.isLocked == true
    }

    func isTimelineEditable(_ item: SubtitleItem) -> Bool {
        !isLocked(item)
            && isInActiveGroup(item)
            && renderModel.group(for: item)?.isOverlayEnabled == true
    }

}
