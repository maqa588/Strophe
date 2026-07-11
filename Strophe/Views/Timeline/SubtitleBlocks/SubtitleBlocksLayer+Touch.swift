//
//  iOS and iPadOS block editing and long-press interaction flow.
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
    #if os(iOS)
    func beginLongPressInteraction(at location: CGPoint) {
        guard renderModel.editingMode == .selection else { return }
        if hitTest(at: location) != nil {
            beginLiftMove(at: location)
        } else if let hitItem = anyBlockHitTest(at: location) {
            if let groupID = renderModel.group(for: hitItem)?.id,
               groupID != renderModel.activeGroupID {
                StyleAndGroupStore.shared.setActiveGroup(groupID)
                beginLiftMove(at: location)
            }
        } else {
            beginMarquee(at: location)
            triggerHapticFeedback()
        }
    }

    func updateLongPressInteraction(_ translation: CGSize) {
        if case .marquee = dragMode, let start = marqueeStart {
            marqueeCurrent = CGPoint(
                x: start.x + translation.width,
                y: start.y + translation.height
            )
            updateSelectionForMarquee()
            ensureMarqueeAutoScrollTask()
        } else {
            updateLiftMove(translation)
        }
    }

    func endLongPressInteraction(commit: Bool) {
        if case .marquee = dragMode {
            if commit {
                updateSelectionForMarquee()
            } else {
                project.selectedIDs.removeAll()
                project.isSubtitleMultiSelecting = false
            }
            resetDragState()
        } else {
            endDirectLift(commit: commit)
        }
    }

    func beginLiftMove(at location: CGPoint) {
        resetDragState()
        guard let hit = hitTest(at: location),
              isTimelineEditable(hit.item),
              let start = hit.item.startTime else { return }
        let item = hit.item
        let end = item.endTime ?? (start + 0.1)

        if !project.selectedIDs.contains(item.id) {
            project.selectedIDs = [item.id]
            project.isSubtitleMultiSelecting = false
        }
        contextItemID = item.id
        activeDragItemID = item.id
        activeDragEdge = nil
        dragSnapGroupID = renderModel.group(for: item)?.id
        dragTargetGroupID = dragSnapGroupID
        movingItemIDs = Set(project.items.lazy.filter {
            project.selectedIDs.contains($0.id) && isTimelineEditable($0)
        }.map(\.id))
        let movingItems = project.items.filter { movingItemIDs.contains($0.id) }
        dragMode = .move(
            itemID: item.id,
            initialStart: movingItems.compactMap(\.startTime).min() ?? start,
            initialEnd: movingItems.compactMap(\.endTime).max() ?? end
        )
        isLiftDragging = true
        liftAnimationStartDate = .now
        triggerLiftHapticFeedback()
    }

    func updateLiftMove(_ translation: CGSize) {
        guard isLiftDragging,
              case .move(_, let initialStart, let initialEnd) = dragMode else { return }
        let delta = Double(translation.width) / pixelsPerSecond
        activeDragDelta = snappedDelta(
            proposals: [
                DragSnapProposal(anchor: .start, initialTime: initialStart, proposedTime: initialStart + delta),
                DragSnapProposal(anchor: .end, initialTime: initialEnd, proposedTime: initialEnd + delta)
            ],
            rawDelta: delta,
            ignoring: movingItemIDs
        )
        updateVerticalTrackDrag(translation: translation.height)
    }

    func endDirectLift(commit: Bool) {
        guard isLiftDragging else { return }
        if commit { commitActiveMove() }
        resetDragState()
    }

    func beginDirectTouchPan(intent: TimelineTouchPanIntent, location: CGPoint) {
        guard renderModel.editingMode == .selection else { return }
        switch intent {
        case .horizontal:
            beginDrag(at: location)
            switch dragMode {
            case .move, .leftEdge, .rightEdge:
                directTouchMode = .blockEdit
            default:
                resetDragState()
                return
            }
        case .vertical:
            directTouchMode = .trackPan
            trackPanStartOffset = trackVerticalOffset
        }
    }

    func updateDirectTouchPan(intent _: TimelineTouchPanIntent, translation: CGSize) {
        switch directTouchMode {
        case .blockEdit:
            updateDirectBlockEdit(translationWidth: translation.width)
        case .trackPan:
            let base = trackPanStartOffset ?? trackVerticalOffset
            let proposed = base - translation.height
                / SubtitleTimelineTrackMetrics.clampedScale(trackVerticalScale)
            trackVerticalOffset = SubtitleTimelineTrackMetrics.clampedOffset(
                proposed,
                trackCount: trackGroups.count,
                scale: trackVerticalScale
            )
        case .none:
            break
        }
    }

    func updateDirectBlockEdit(translationWidth: CGFloat) {
        let delta = Double(translationWidth) / pixelsPerSecond
        switch dragMode {
        case .move(_, let initialStart, let initialEnd):
            activeDragDelta = snappedDelta(proposals: [
                DragSnapProposal(anchor: .start, initialTime: initialStart, proposedTime: initialStart + delta),
                DragSnapProposal(anchor: .end, initialTime: initialEnd, proposedTime: initialEnd + delta)
            ], rawDelta: delta, ignoring: movingItemIDs)
        case .leftEdge(let itemID, let initialStart, _):
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
            activeDragDelta = snappedDelta(
                proposals: [DragSnapProposal(
                    anchor: .end,
                    initialTime: initialEnd,
                    proposedTime: initialEnd + delta
                )],
                rawDelta: delta,
                ignoring: [itemID]
            )
        case .marquee, .ignored, .none:
            break
        }
    }

    func endDirectTouchPan(intent _: TimelineTouchPanIntent, commit: Bool) {
        switch directTouchMode {
        case .blockEdit:
            if commit { commitActiveBlockEdit() }
            resetDragState()
        case .trackPan:
            trackPanStartOffset = nil
            directTouchMode = .none
        case .none:
            break
        }
    }
    #endif

}
