import CoreGraphics
import Foundation

nonisolated struct ResolvedSubtitlePosition: Sendable, Equatable, Hashable {
    var x: Double?
    var y: Double?
    var coordinateSpace: SubtitlePositionCoordinateSpace
    var anchor: SubtitleStyle.Alignment

    var isAbsolute: Bool {
        x != nil || y != nil
    }
}

nonisolated struct SubtitleBitmapMetrics: Sendable, Equatable {
    /// Final bitmap size after scale and rotation.
    var size: CGSize
    /// Location of the authored anchor inside the final bitmap, in top-left coordinates.
    var anchorOffset: CGPoint
}

nonisolated struct SubtitleFrameSceneItem: Identifiable, Sendable, Equatable {
    var id: UUID { cue.id }
    var cue: ResolvedSubtitleCue
    /// Final bitmap origin in the video's top-left coordinate system.
    var origin: CGPoint
    var size: CGSize
    /// Authored anchor after collision resolution, in video coordinates.
    var anchorPoint: CGPoint

    var frame: CGRect {
        CGRect(origin: origin, size: size)
    }
}

nonisolated struct SubtitleFrameScene: Sendable, Equatable {
    var presentationTime: Double
    var canvasSize: CGSize
    /// Back-to-front render order.
    var items: [SubtitleFrameSceneItem]

    static func empty(at time: Double, canvasSize: CGSize) -> SubtitleFrameScene {
        SubtitleFrameScene(presentationTime: time, canvasSize: canvasSize, items: [])
    }
}

/// Resolves timing, absolute positioning, anchors, layer order and automatic
/// collision displacement once for both preview and hard-subtitle export.
nonisolated enum SubtitleFrameSceneResolver {
    typealias MetricsProvider = (ResolvedSubtitleCue) -> SubtitleBitmapMetrics?

    static func resolve(
        cues: [ResolvedSubtitleCue],
        at time: Double,
        canvasSize: CGSize,
        collisionMode: SubtitleCollisionMode,
        forcedCueIDs: Set<UUID> = [],
        metricsProvider: MetricsProvider
    ) -> SubtitleFrameScene {
        guard time.isFinite,
              canvasSize.width > 0,
              canvasSize.height > 0 else {
            return .empty(at: time, canvasSize: canvasSize)
        }

        let active = cues.filter { cue in
            forcedCueIDs.contains(cue.id)
                || (time >= cue.startTime && time < cue.endTime)
        }
        guard !active.isEmpty else {
            return .empty(at: time, canvasSize: canvasSize)
        }

        var drafts = active.compactMap { cue -> Draft? in
            guard let metrics = metricsProvider(cue),
                  metrics.size.width > 0,
                  metrics.size.height > 0 else {
                return nil
            }

            let anchor = authoredAnchor(for: cue, canvasSize: canvasSize)
            return Draft(
                cue: cue,
                metrics: metrics,
                authoredAnchor: anchor,
                resolvedAnchor: anchor,
                isAbsolute: cue.position?.isAbsolute == true
            )
        }

        if collisionMode != .disabled {
            resolveCollisions(
                drafts: &drafts,
                canvasSize: canvasSize,
                mode: collisionMode
            )
        }

        let items = drafts.map { draft in
            SubtitleFrameSceneItem(
                cue: draft.cue,
                origin: CGPoint(
                    x: draft.resolvedAnchor.x - draft.metrics.anchorOffset.x,
                    y: draft.resolvedAnchor.y - draft.metrics.anchorOffset.y
                ),
                size: draft.metrics.size,
                anchorPoint: draft.resolvedAnchor
            )
        }
        .sorted(by: renderOrder)

        return SubtitleFrameScene(
            presentationTime: time,
            canvasSize: canvasSize,
            items: items
        )
    }

    private struct Draft {
        var cue: ResolvedSubtitleCue
        var metrics: SubtitleBitmapMetrics
        var authoredAnchor: CGPoint
        var resolvedAnchor: CGPoint
        var isAbsolute: Bool

        var frame: CGRect {
            CGRect(
                x: resolvedAnchor.x - metrics.anchorOffset.x,
                y: resolvedAnchor.y - metrics.anchorOffset.y,
                width: metrics.size.width,
                height: metrics.size.height
            )
        }
    }

    private static func authoredAnchor(
        for cue: ResolvedSubtitleCue,
        canvasSize: CGSize
    ) -> CGPoint {
        let placementRect = SubtitlePlacementMetrics.placementRect(
            for: canvasSize,
            style: cue.style
        )
        var point = placementAnchor(
            in: placementRect,
            alignment: cue.resolvedAnchor
        )

        guard let position = cue.position, position.isAbsolute else {
            return point
        }

        if let x = position.x, x.isFinite {
            point.x = position.coordinateSpace == .normalized
                ? CGFloat(x) * canvasSize.width
                : CGFloat(x)
        }
        if let y = position.y, y.isFinite {
            point.y = position.coordinateSpace == .normalized
                ? CGFloat(y) * canvasSize.height
                : CGFloat(y)
        }
        return point
    }

    private static func placementAnchor(
        in rect: CGRect,
        alignment: SubtitleStyle.Alignment
    ) -> CGPoint {
        let x: CGFloat
        switch alignment {
        case .topLeft, .middleLeft, .bottomLeft:
            x = rect.minX
        case .topCenter, .middleCenter, .bottomCenter:
            x = rect.midX
        case .topRight, .middleRight, .bottomRight:
            x = rect.maxX
        }

        let y: CGFloat
        switch alignment {
        case .topLeft, .topCenter, .topRight:
            y = rect.minY
        case .middleLeft, .middleCenter, .middleRight:
            y = rect.midY
        case .bottomLeft, .bottomCenter, .bottomRight:
            y = rect.maxY
        }
        return CGPoint(x: x, y: y)
    }

    private static func resolveCollisions(
        drafts: inout [Draft],
        canvasSize: CGSize,
        mode: SubtitleCollisionMode
    ) {
        let orderedIndices = drafts.indices
            .filter { !drafts[$0].isAbsolute }
            .sorted { lhsIndex, rhsIndex in
                collisionOrder(
                    drafts[lhsIndex].cue,
                    drafts[rhsIndex].cue,
                    mode: mode
                )
            }

        var occupiedByLayer: [Int: [CGRect]] = [:]
        for index in orderedIndices {
            let layer = drafts[index].cue.layer
            let occupied = occupiedByLayer[layer] ?? []
            let gap = collisionGap(for: drafts[index].cue, canvasSize: canvasSize)
            let preferredDirection = collisionDirection(
                for: drafts[index].cue.resolvedAnchor
            )
            let placedFrame = place(
                drafts[index].frame,
                avoiding: occupied,
                canvasSize: canvasSize,
                gap: gap,
                preferredDirection: preferredDirection
            )

            drafts[index].resolvedAnchor.y += placedFrame.minY - drafts[index].frame.minY
            occupiedByLayer[layer, default: []].append(placedFrame)
        }
    }

    private static func place(
        _ frame: CGRect,
        avoiding occupied: [CGRect],
        canvasSize: CGSize,
        gap: CGFloat,
        preferredDirection: CGFloat
    ) -> CGRect {
        guard occupied.contains(where: { $0.intersects(frame) }) else {
            return frame
        }

        if let preferred = collisionFreeFrame(
            frame,
            avoiding: occupied,
            canvasSize: canvasSize,
            gap: gap,
            direction: preferredDirection
        ) {
            return preferred
        }
        if let fallback = collisionFreeFrame(
            frame,
            avoiding: occupied,
            canvasSize: canvasSize,
            gap: gap,
            direction: -preferredDirection
        ) {
            return fallback
        }

        var clamped = frame
        clamped.origin.y = min(
            max(0, clamped.origin.y),
            max(0, canvasSize.height - clamped.height)
        )
        return clamped
    }

    private static func collisionFreeFrame(
        _ source: CGRect,
        avoiding occupied: [CGRect],
        canvasSize: CGSize,
        gap: CGFloat,
        direction: CGFloat
    ) -> CGRect? {
        var candidate = source
        var iteration = 0
        while let conflict = occupied.first(where: { $0.intersects(candidate) }) {
            if direction < 0 {
                candidate.origin.y = conflict.minY - gap - candidate.height
            } else {
                candidate.origin.y = conflict.maxY + gap
            }

            guard candidate.minY >= 0,
                  candidate.maxY <= canvasSize.height else {
                return nil
            }
            iteration += 1
            guard iteration <= occupied.count else { return nil }
        }
        return candidate
    }

    private static func collisionDirection(
        for alignment: SubtitleStyle.Alignment
    ) -> CGFloat {
        switch alignment {
        case .topLeft, .topCenter, .topRight:
            return 1
        case .middleLeft, .middleCenter, .middleRight,
             .bottomLeft, .bottomCenter, .bottomRight:
            return -1
        }
    }

    private static func collisionGap(
        for cue: ResolvedSubtitleCue,
        canvasSize: CGSize
    ) -> CGFloat {
        let scale = max(0.42, min(canvasSize.height / 1080.0, 2.2))
        return max(2, CGFloat(cue.style.fontSize) * scale * 0.08)
    }

    private static func collisionOrder(
        _ lhs: ResolvedSubtitleCue,
        _ rhs: ResolvedSubtitleCue,
        mode: SubtitleCollisionMode
    ) -> Bool {
        let comparison: ComparisonResult
        if lhs.trackIndex != rhs.trackIndex {
            comparison = lhs.trackIndex < rhs.trackIndex ? .orderedAscending : .orderedDescending
        } else if lhs.startTime != rhs.startTime {
            comparison = lhs.startTime < rhs.startTime ? .orderedAscending : .orderedDescending
        } else {
            comparison = lhs.id.uuidString.compare(rhs.id.uuidString)
        }
        switch mode {
        case .normal, .disabled:
            return comparison == .orderedAscending
        case .reverse:
            return comparison == .orderedDescending
        }
    }

    private static func renderOrder(
        _ lhs: SubtitleFrameSceneItem,
        _ rhs: SubtitleFrameSceneItem
    ) -> Bool {
        if lhs.cue.layer != rhs.cue.layer {
            return lhs.cue.layer < rhs.cue.layer
        }
        if lhs.cue.trackIndex != rhs.cue.trackIndex {
            return lhs.cue.trackIndex < rhs.cue.trackIndex
        }
        if lhs.cue.startTime != rhs.cue.startTime {
            return lhs.cue.startTime < rhs.cue.startTime
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
