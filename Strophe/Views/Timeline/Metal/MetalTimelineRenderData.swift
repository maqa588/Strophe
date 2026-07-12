import CoreText
import MetalKit
import SwiftUI
import simd

nonisolated struct MetalTimelineBlockRenderData: Equatable, Sendable {
    var id: UUID
    var rect: CGRect
    var fillColor: ResolvedRGBAColor
    var strokeColor: ResolvedRGBAColor
    var textColor: ResolvedRGBAColor
    var markerColor: ResolvedRGBAColor
    var strokeWidth: CGFloat
    var isLocked: Bool
    var hasIndependentPresentation: Bool
    var showsTrimHandles: Bool
    var liftProgress: Float
    var text: String
    var isCompact: Bool
}

nonisolated struct MetalTimelineLaneRenderData: Equatable, Sendable {
    var rect: CGRect
    var fillColor: ResolvedRGBAColor
    var separatorColor: ResolvedRGBAColor
}

nonisolated struct MetalTimelineFrameRenderData: Equatable, Sendable {
    var viewportSize: CGSize
    var lanes: [MetalTimelineLaneRenderData]
    var blocks: [MetalTimelineBlockRenderData]
    var overlapRects: [CGRect]
    var marqueeRect: CGRect?

    static let empty = MetalTimelineFrameRenderData(
        viewportSize: .zero,
        lanes: [],
        blocks: [],
        overlapRects: [],
        marqueeRect: nil
    )
}

struct MetalStaticSubtitleTimelineLayer: View, Equatable {
    let renderRevision: UInt64
    let items: [SubtitleItem]
    let groups: [SubGroupItem]
    let selectedIDs: Set<UUID>
    let excludedIDs: Set<UUID>
    let trimHandleItemIDs: Set<UUID>
    let pixelsPerSecond: Double
    let visibleStartTime: Double
    let viewWidth: CGFloat
    let trackVerticalScale: CGFloat
    let trackVerticalOffset: CGFloat
    let isCompact: Bool
    let colorScheme: ColorScheme

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.renderRevision == rhs.renderRevision
            && lhs.selectedIDs == rhs.selectedIDs
            && lhs.excludedIDs == rhs.excludedIDs
            && lhs.trimHandleItemIDs == rhs.trimHandleItemIDs
            && lhs.pixelsPerSecond == rhs.pixelsPerSecond
            && lhs.visibleStartTime == rhs.visibleStartTime
            && lhs.viewWidth == rhs.viewWidth
            && lhs.trackVerticalScale == rhs.trackVerticalScale
            && lhs.trackVerticalOffset == rhs.trackVerticalOffset
            && lhs.isCompact == rhs.isCompact
            && lhs.colorScheme == rhs.colorScheme
    }

    var body: some View {
        let viewportOriginX = CGFloat(visibleStartTime * pixelsPerSecond)
        let trackGroups = sortedVisibleGroups
        let groupByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let fallbackGroup = groups.first
        let trackIndexByGroupID = Dictionary(uniqueKeysWithValues: trackGroups.enumerated().map { ($0.element.id, $0.offset) })
        let viewportSize = CGSize(
            width: viewWidth,
            height: SubtitleTimelineTrackMetrics.totalHeight(trackCount: trackGroups.count)
        )
        let lanes = trackGroups.enumerated().map { index, group in
            let isActive = group.isActive
            return MetalTimelineLaneRenderData(
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
                fillColor: group.color.resolvedRGBA.withAlpha(isActive ? 0.10 : (index.isMultiple(of: 2) ? 0.035 : 0.055)),
                separatorColor: group.color.resolvedRGBA.withAlpha(isActive ? 0.42 : 0.18)
            )
        }
        let blocks = items.compactMap { item -> MetalTimelineBlockRenderData? in
            guard !excludedIDs.contains(item.id),
                  let start = item.startTime,
                  let group = item.groupID.flatMap({ groupByID[$0] }) ?? fallbackGroup,
                  group.isOverlayEnabled else { return nil }
            let end = item.endTime ?? (start + 0.1)
            return makeBlock(
                item: item,
                group: group,
                trackIndex: trackIndexByGroupID[group.id] ?? 0,
                start: start,
                end: end,
                viewportOriginX: viewportOriginX
            )
        }

        MetalSubtitleTimelineView(
            renderData: MetalTimelineFrameRenderData(
                viewportSize: viewportSize,
                lanes: lanes,
                blocks: blocks,
                overlapRects: [],
                marqueeRect: nil
            )
        )
        .frame(width: viewWidth, height: viewportSize.height)
        .offset(x: viewportOriginX)
        .allowsHitTesting(false)
    }

    private func makeBlock(
        item: SubtitleItem,
        group: SubGroupItem,
        trackIndex: Int,
        start: Double,
        end: Double,
        viewportOriginX: CGFloat
    ) -> MetalTimelineBlockRenderData {
        let groupColor = group.color.resolvedRGBA
        let isSelected = selectedIDs.contains(item.id)
        let isLocked = item.isLocked || group.isLocked
        let isGroupVisible = group.isOverlayEnabled
        let isDimmed = item.isHidden || !group.isOverlayEnabled
        let opacity = isDimmed ? 0.42 : 1.0
        let primary = colorScheme == .dark
            ? ResolvedRGBAColor(red: 0.94, green: 0.93, blue: 0.91, alpha: opacity)
            : ResolvedRGBAColor(red: 0.08, green: 0.08, blue: 0.08, alpha: opacity)

        return MetalTimelineBlockRenderData(
            id: item.id,
            rect: CGRect(
                x: CGFloat(start * pixelsPerSecond) - viewportOriginX,
                y: SubtitleTimelineTrackMetrics.blockY(
                    trackIndex: trackIndex,
                    scale: trackVerticalScale,
                    offset: trackVerticalOffset
                ),
                width: max(4, CGFloat((end - start) * pixelsPerSecond)),
                height: SubtitleTimelineTrackMetrics.scaledBlockHeight(trackVerticalScale)
            ),
            fillColor: groupColor.withAlpha((isSelected ? 0.62 : 0.28) * opacity),
            strokeColor: (isSelected ? Color.yellow.resolvedRGBA : groupColor).withAlpha(opacity),
            textColor: isSelected ? .white.withAlpha(opacity) : primary,
            markerColor: isSelected ? .white.withAlpha(opacity) : groupColor.withAlpha(opacity),
            strokeWidth: isSelected ? 2 : 1,
            isLocked: isLocked,
            hasIndependentPresentation: item.hasIndependentPresentation,
            showsTrimHandles: trimHandleItemIDs.contains(item.id) && !isLocked && isGroupVisible,
            liftProgress: 0,
            text: item.text,
            isCompact: isCompact
        )
    }

    private var sortedVisibleGroups: [SubGroupItem] {
        groups
            .filter(\.isOverlayEnabled)
            .sorted { lhs, rhs in
                lhs.sortOrder == rhs.sortOrder ? lhs.name < rhs.name : lhs.sortOrder < rhs.sortOrder
            }
    }

}

#if os(macOS)
struct MetalSubtitleTimelineView: NSViewRepresentable {
    let renderData: MetalTimelineFrameRenderData

    func makeNSView(context: Context) -> MetalSubtitleTimelineRenderer {
        MetalSubtitleTimelineRenderer()
    }

    func updateNSView(_ view: MetalSubtitleTimelineRenderer, context: Context) {
        view.update(renderData: renderData)
    }
}
#else
struct MetalSubtitleTimelineView: UIViewRepresentable {
    let renderData: MetalTimelineFrameRenderData

    func makeUIView(context: Context) -> MetalSubtitleTimelineRenderer {
        MetalSubtitleTimelineRenderer()
    }

    func updateUIView(_ view: MetalSubtitleTimelineRenderer, context: Context) {
        view.update(renderData: renderData)
    }
}
#endif
