//
//  Builds static and dynamic Metal render data for subtitle tracks.
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
    func metalRenderData(
        item: SubtitleItem,
        end: Double,
        compact: Bool
    ) -> MetalTimelineFrameRenderData {
        guard let start = item.startTime,
              renderModel.group(for: item)?.isOverlayEnabled == true else { return .empty }
        return MetalTimelineFrameRenderData(
            viewportSize: CGSize(width: viewWidth, height: timelineHeight),
            lanes: [],
            blocks: [metalBlock(item: item, start: start, end: end, compact: compact)],
            overlapRects: [],
            marqueeRect: nil
        )
    }

    func dynamicMetalRenderData(
        itemIDs: Set<UUID>,
        compact: Bool,
        liftProgress: CGFloat
    ) -> MetalTimelineFrameRenderData {
        let draggedBlocks = itemIDs.compactMap { renderModel.item(id: $0) }.compactMap { item -> MetalTimelineBlockRenderData? in
            guard let start = item.startTime else { return nil }
            let end = item.endTime ?? (start + 0.1)
            let times = displayedTimes(for: item, start: start, end: end)
            guard times.end >= renderRange.lowerBound, times.start <= renderRange.upperBound else { return nil }
            return metalBlock(
                item: item,
                start: times.start,
                end: times.end,
                compact: compact,
                liftProgress: isLiftDragging ? liftProgress : 0
            )
        }

        let viewportOriginX = CGFloat(visibleStartTime * pixelsPerSecond)
        let targetLanes: [MetalTimelineLaneRenderData]
        if activeDragVerticalDelta != 0,
           let dragTargetGroupID,
           let index = trackGroups.firstIndex(where: { $0.id == dragTargetGroupID }) {
            let group = trackGroups[index]
            targetLanes = [MetalTimelineLaneRenderData(
                rect: CGRect(
                    x: 0,
                    y: SubtitleTimelineTrackMetrics.laneY(
                        trackIndex: index,
                        scale: trackVerticalScale,
                        offset: trackVerticalOffset
                    ),
                    width: viewWidth,
                    height: SubtitleTimelineTrackMetrics.scaledTrackPitch(trackVerticalScale)
                ),
                fillColor: group.color.resolvedRGBA.withAlpha(0.18),
                separatorColor: group.color.resolvedRGBA.withAlpha(0.8)
            )]
        } else {
            targetLanes = []
        }
        let overlaps = renderModel.overlappingIntervals(in: renderModel.activeGroupID).compactMap { interval -> CGRect? in
            guard interval.end >= renderRange.lowerBound, interval.start <= renderRange.upperBound else { return nil }
            return CGRect(
                x: CGFloat(interval.start * pixelsPerSecond) - viewportOriginX,
                y: activeTrackBlockY,
                width: max(1, CGFloat((interval.end - interval.start) * pixelsPerSecond)),
                height: SubtitleTimelineTrackMetrics.scaledBlockHeight(trackVerticalScale)
            )
        }

        let marquee: CGRect?
        if let start = marqueeStart, let current = marqueeCurrent {
            var rect = SubtitleMarqueeSelectionGeometry.normalizedRect(from: start, to: current)
            rect.origin.x -= viewportOriginX
            marquee = rect
        } else {
            marquee = nil
        }

        return MetalTimelineFrameRenderData(
            viewportSize: CGSize(width: viewWidth, height: timelineHeight),
            lanes: targetLanes,
            blocks: draggedBlocks,
            overlapRects: overlaps,
            marqueeRect: marquee
        )
    }

    func metalBlock(
        item: SubtitleItem,
        start: Double,
        end: Double,
        compact: Bool,
        liftProgress: CGFloat = 0
    ) -> MetalTimelineBlockRenderData {
        let group = renderModel.group(for: item)
        let groupColor = (group?.color ?? Color.stropheBlue).resolvedRGBA
        let isSelected = renderModel.selectedIDs.contains(item.id)
        let isLocked = item.isLocked || group?.isLocked == true
        let isDimmed = item.isHidden || group?.isOverlayEnabled == false
        let opacity = isDimmed ? 0.42 : 1.0
        let fillAlpha = (isSelected ? 0.62 : 0.28) * opacity
        let primary = colorScheme == .dark
            ? ResolvedRGBAColor(red: 0.94, green: 0.93, blue: 0.91, alpha: opacity)
            : ResolvedRGBAColor(red: 0.08, green: 0.08, blue: 0.08, alpha: opacity)
        let viewportOriginX = CGFloat(visibleStartTime * pixelsPerSecond)

        let clampedLift = min(1.08, max(0, liftProgress))
        let baseWidth = max(4, CGFloat((end - start) * pixelsPerSecond))
        let baseHeight = SubtitleTimelineTrackMetrics.scaledBlockHeight(trackVerticalScale)
        let expansionX = baseWidth * 0.025 * clampedLift
        let expansionY = baseHeight * 0.07 * clampedLift

        return MetalTimelineBlockRenderData(
            id: item.id,
            rect: CGRect(
                x: CGFloat(start * pixelsPerSecond) - viewportOriginX - expansionX,
                y: displayedBlockY(for: item) - 4 * clampedLift - expansionY,
                width: baseWidth + expansionX * 2,
                height: baseHeight + expansionY * 2
            ),
            fillColor: groupColor.withAlpha(fillAlpha),
            strokeColor: (isSelected ? Color.yellow.resolvedRGBA : groupColor).withAlpha(opacity),
            textColor: isSelected ? .white.withAlpha(opacity) : primary,
            markerColor: isSelected ? .white.withAlpha(opacity) : groupColor.withAlpha(opacity),
            strokeWidth: isSelected ? 2 : 1,
            isLocked: isLocked,
            hasIndependentPresentation: item.hasIndependentPresentation,
            showsTrimHandles: trimHandleItemIDs.contains(item.id)
                && !isLocked
                && isTimelineEditable(item),
            liftProgress: Float(clampedLift),
            text: item.text,
            isCompact: compact
        )
    }

    @ViewBuilder
    func interactionOverlay(for items: [SubtitleItem]) -> some View {
        #if os(macOS)
        Color.clear
            .contentShape(Rectangle())
            .gesture(blockDragGesture)
            .onTapGesture(coordinateSpace: .local) { handleTap(at: $0) }
            .simultaneousGesture(
                SpatialTapGesture(count: 2, coordinateSpace: .local)
                    .onEnded { handleDoubleTap(at: $0.location) }
            )
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let hit = hitTest(at: location)
                    let newID = hit?.item.id
                    if contextItemID != newID { contextItemID = newID }
                    if hoveredItemID != newID { hoveredItemID = newID }
                    updateTimelineCursor(
                        isOverTrimHandle: hit.map { $0.edge != nil && isTimelineEditable($0.item) } ?? false
                    )
                case .ended:
                    hoveredItemID = nil
                    updateTimelineCursor(isOverTrimHandle: false)
                }
            }
            .contextMenu {
                if let contextItem { blockContextMenu(for: contextItem) }
            }
            .simultaneousGesture(trackViewportPanGesture)
        #else
        TimelineTouchInteractionSurface(
            containsBlock: { anyBlockHitTest(at: $0) != nil },
            canBeginLongPress: {
                renderModel.editingMode == .selection && isPointInsideTimeline($0)
            },
            shouldBeginPan: { intent, location in
                switch intent {
                case .horizontal:
                    return anyBlockHitTest(at: location) != nil
                case .vertical:
                    return true
                }
            },
            onPanBegan: beginDirectTouchPan,
            onPanChanged: updateDirectTouchPan,
            onPanEnded: endDirectTouchPan,
            onLongPressBegan: beginLongPressInteraction,
            onLongPressChanged: updateLongPressInteraction,
            onLongPressEnded: endLongPressInteraction,
            onSingleTap: handleTap,
            onDoubleTap: handleMobileDoubleTap
        )
        #endif
    }

    var trackViewportPanGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                guard !isLiftDragging,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                #if os(macOS)
                guard hitTest(at: value.startLocation) == nil else { return }
                #endif
                if trackPanStartOffset == nil {
                    trackPanStartOffset = trackVerticalOffset
                }
                let base = trackPanStartOffset ?? trackVerticalOffset
                let proposed = base - value.translation.height / SubtitleTimelineTrackMetrics.clampedScale(trackVerticalScale)
                trackVerticalOffset = SubtitleTimelineTrackMetrics.clampedOffset(
                    proposed,
                    trackCount: trackGroups.count,
                    scale: trackVerticalScale
                )
            }
            .onEnded { _ in trackPanStartOffset = nil }
    }

    func clampTrackViewport() {
        let clampedScale = SubtitleTimelineTrackMetrics.clampedScale(trackVerticalScale)
        if clampedScale != trackVerticalScale { trackVerticalScale = clampedScale }
        let clampedOffset = SubtitleTimelineTrackMetrics.clampedOffset(
            trackVerticalOffset,
            trackCount: trackGroups.count,
            scale: clampedScale
        )
        if clampedOffset != trackVerticalOffset { trackVerticalOffset = clampedOffset }
    }

    func interactionRects(for items: [SubtitleItem]) -> [CGRect] {
        items.compactMap { item in
            guard isTimelineEditable(item), let start = item.startTime else { return nil }
            var end = item.endTime ?? (start + 0.1)
            if item.id == renderModel.activeSlapSubtitleID {
                end = activeSlapEnd(for: item, at: .now)
            }
            let displayed = displayedTimes(for: item, start: start, end: end)
            return CGRect(
                x: CGFloat(displayed.start * pixelsPerSecond),
                y: blockY(for: item),
                width: max(4, CGFloat((displayed.end - displayed.start) * pixelsPerSecond)),
                height: SubtitleTimelineTrackMetrics.scaledBlockHeight(trackVerticalScale)
            )
        }
    }

    var activeTrackBlockY: CGFloat {
        guard let activeGroupID = renderModel.activeGroupID,
              let index = trackGroups.firstIndex(where: { $0.id == activeGroupID }) else {
            return SubtitleTimelineTrackMetrics.blockY(
                trackIndex: 0,
                scale: trackVerticalScale,
                offset: trackVerticalOffset
            )
        }
        return SubtitleTimelineTrackMetrics.blockY(
            trackIndex: index,
            scale: trackVerticalScale,
            offset: trackVerticalOffset
        )
    }

    func blockY(for item: SubtitleItem) -> CGFloat {
        guard let groupID = renderModel.group(for: item)?.id,
              let index = trackGroups.firstIndex(where: { $0.id == groupID }) else {
            return SubtitleTimelineTrackMetrics.blockY(
                trackIndex: 0,
                scale: trackVerticalScale,
                offset: trackVerticalOffset
            )
        }
        return SubtitleTimelineTrackMetrics.blockY(
            trackIndex: index,
            scale: trackVerticalScale,
            offset: trackVerticalOffset
        )
    }

    func displayedBlockY(for item: SubtitleItem) -> CGFloat {
        guard activeDragEdge == nil, movingItemIDs.contains(item.id) else {
            return blockY(for: item)
        }
        return blockY(for: item) + activeDragVerticalDelta
    }

    func displayedTimes(for item: SubtitleItem, start: Double, end: Double) -> (start: Double, end: Double) {
        if item.id == activeDragItemID {
            if activeDragEdge == .left {
                return (start + activeDragDelta, end)
            }
            if activeDragEdge == .right {
                return (start, end + activeDragDelta)
            }
        }
        if activeDragEdge == nil, movingItemIDs.contains(item.id) {
            return (start + activeDragDelta, end + activeDragDelta)
        }
        return (start, end)
    }

    func activeSlapEnd(for item: SubtitleItem, at date: Date) -> Double {
        guard let start = item.startTime else { return item.endTime ?? 0 }
        let rawTime = project.isScrubbing
            ? project.currentTime
            : project.referenceTime + date.timeIntervalSince(project.referenceDate) * project.playbackRate
        let finiteTime = rawTime.isFinite ? rawTime : project.currentTime
        return max(start + minimumFrameDuration, min(workspaceDuration, finiteTime))
    }

    var minimumFrameDuration: Double {
        project.videoFrameRate > 0 ? 1.0 / project.videoFrameRate : 0.1
    }

}
