//
//  SubtitleBlocksLayer.swift
//  Strophe
//
//  Created by maqa on 2026/5/17.
//

import Combine
import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import GameController
#endif

let subtitleBlocksCoordinateSpaceName = "subtitleBlocksCoordinateSpace"

private nonisolated struct SubtitleBlockHitShape: Shape {
    let rects: [CGRect]

    func path(in _: CGRect) -> Path {
        var path = Path()
        for rect in rects {
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: 4, height: 4))
        }
        return path
    }
}

/// A narrow projection of SubtitleProject for the timeline renderer.
///
/// SubtitleProject owns playback, document, selection and editor state. Observing it
/// directly from every subtitle block caused unrelated changes (for example the
/// current subtitle index) to invalidate the entire block hierarchy. This model only
/// republishes values that can actually change block pixels or block interaction.
@MainActor
private final class SubtitleBlocksRenderModel: ObservableObject {
    @Published private(set) var items: [SubtitleItem]
    @Published private(set) var selectedIDs: Set<UUID>
    @Published private(set) var editingMode: TimelineEditingMode
    @Published private(set) var activeSlapSubtitleID: UUID?
    @Published private(set) var groups: [SubGroupItem]
    @Published private(set) var styles: [SubgroupStyle]

    private(set) var renderRevision: UInt64 = 0
    private(set) var timelineIndex = TimelineIndex()
    private var itemByID: [UUID: SubtitleItem] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(project: SubtitleProject, store: StyleAndGroupStore = .shared) {
        items = project.items
        selectedIDs = project.selectedIDs
        editingMode = project.editingMode
        activeSlapSubtitleID = project.activeSlapSubtitleID
        groups = store.groups
        styles = store.styles
        itemByID = Dictionary(uniqueKeysWithValues: project.items.map { ($0.id, $0) })
        timelineIndex.rebuild(with: project.items)

        project.$items
            .dropFirst()
            .sink { [weak self] in self?.replaceItems($0) }
            .store(in: &cancellables)
        project.$selectedIDs
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self, self.selectedIDs != newValue else { return }
                self.renderRevision &+= 1
                self.selectedIDs = newValue
            }
            .store(in: &cancellables)
        project.$editingMode
            .dropFirst()
            .sink { [weak self] in self?.editingMode = $0 }
            .store(in: &cancellables)
        project.$activeSlapSubtitleID
            .dropFirst()
            .sink { [weak self] in self?.activeSlapSubtitleID = $0 }
            .store(in: &cancellables)
        store.$groups
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self, self.groups != newValue else { return }
                self.renderRevision &+= 1
                self.groups = newValue
            }
            .store(in: &cancellables)
        store.$styles
            .dropFirst()
            .sink { [weak self] in self?.styles = $0 }
            .store(in: &cancellables)
    }

    func item(id: UUID?) -> SubtitleItem? {
        id.flatMap { itemByID[$0] }
    }

    func visibleItems(in range: ClosedRange<Double>) -> [SubtitleItem] {
        timelineIndex.visibleItems(in: range)
    }

    func group(for item: SubtitleItem) -> SubGroupItem? {
        groups.first(where: { $0.id == item.groupID })
            ?? groups.first(where: \.isActive)
            ?? groups.first
    }

    var activeGroupID: UUID? {
        groups.first(where: \.isActive)?.id ?? groups.first?.id
    }

    var sortedGroups: [SubGroupItem] {
        groups.sorted { lhs, rhs in
            lhs.sortOrder == rhs.sortOrder ? lhs.name < rhs.name : lhs.sortOrder < rhs.sortOrder
        }
    }

    private func replaceItems(_ newItems: [SubtitleItem]) {
        guard items != newItems else { return }
        renderRevision &+= 1
        items = newItems
        itemByID = Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, $0) })
        timelineIndex.rebuild(with: newItems)
    }
}

// MARK: - Unified subtitle drawing and interaction layer

struct SubtitleBlocksLayer: View {
    let project: SubtitleProject
    let pixelsPerSecond: Double
    let visibleStartTime: Double
    let viewWidth: CGFloat
    let workspaceDuration: Double
    @Binding var scrollPageStartTime: Double

    @StateObject private var renderModel: SubtitleBlocksRenderModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var marqueeStart: CGFloat?
    @State private var marqueeCurrent: CGFloat?
    @State private var marqueeAutoScrollTask: Task<Void, Never>?

    @State private var dragMode: BlockDragMode = .none
    @State private var activeDragItemID: UUID?
    @State private var activeDragEdge: TimelineInteractionLayer.Edge?
    @State private var activeDragDelta: Double = 0
    @State private var movingItemIDs: Set<UUID> = []
    @State private var isSnapped = false

    @State private var contextItemID: UUID?
    @State private var editingItemID: UUID?
    @State private var editingText = ""
    @State private var isEditingText = false
    @State private var editingStartText = ""
    @State private var editingEndText = ""
    @State private var isEditingTime = false

    private let blockHeight: CGFloat = 30
    private let blockY: CGFloat = 80
    private let marqueeAutoScrollEdgeInset: CGFloat = 72
    private let marqueeAutoScrollMaxSpeed: CGFloat = 560
    private let marqueeAutoScrollFrameInterval: TimeInterval = 1.0 / 60.0

    private enum BlockDragMode {
        case move(itemID: UUID, initialStart: Double, initialEnd: Double)
        case leftEdge(itemID: UUID, initialStart: Double, initialEnd: Double)
        case rightEdge(itemID: UUID, initialStart: Double, initialEnd: Double)
        case marquee
        case ignored
        case none
    }

    init(
        project: SubtitleProject,
        pixelsPerSecond: Double,
        visibleStartTime: Double,
        viewWidth: CGFloat,
        workspaceDuration: Double,
        scrollPageStartTime: Binding<Double>
    ) {
        self.project = project
        self.pixelsPerSecond = pixelsPerSecond
        self.visibleStartTime = visibleStartTime
        self.viewWidth = viewWidth
        self.workspaceDuration = workspaceDuration
        _scrollPageStartTime = scrollPageStartTime
        _renderModel = StateObject(wrappedValue: SubtitleBlocksRenderModel(project: project))
    }

    private var visiblePadding: Double {
        Double(viewWidth) / pixelsPerSecond * 0.3
    }

    private var renderRange: ClosedRange<Double> {
        let start = max(0, visibleStartTime - visiblePadding)
        let end = visibleStartTime + Double(viewWidth) / pixelsPerSecond + visiblePadding
        return start...end
    }

    private var visibleItems: [SubtitleItem] {
        renderModel.visibleItems(in: renderRange)
    }

    private var contextItem: SubtitleItem? {
        renderModel.item(id: contextItemID)
    }

    var body: some View {
        let drawnItems = visibleItems
        let activeSlapID = renderModel.activeSlapSubtitleID
        let usesCompactLOD = drawnItems.count > 150
        let dynamicIDs = dynamicDragItemIDs
        let excludedStaticIDs = dynamicIDs.union(activeSlapID.map { [$0] } ?? [])
        let viewportOriginX = CGFloat(visibleStartTime * pixelsPerSecond)
        let renderHeight = blockY + blockHeight + 10

        ZStack(alignment: .topLeading) {
            MetalStaticSubtitleTimelineLayer(
                renderRevision: renderModel.renderRevision,
                items: drawnItems,
                groups: renderModel.groups,
                selectedIDs: renderModel.selectedIDs,
                excludedIDs: excludedStaticIDs,
                pixelsPerSecond: pixelsPerSecond,
                visibleStartTime: visibleStartTime,
                viewWidth: viewWidth,
                blockY: blockY,
                blockHeight: blockHeight,
                isCompact: usesCompactLOD,
                colorScheme: colorScheme
            )
            .equatable()

            // Only the one actively growing slap block is clock-driven. The static
            // Metal surface above never subscribes to the animation timeline.
            if let activeSlapID,
               let activeItem = renderModel.item(id: activeSlapID),
               activeItem.startTime != nil {
                TimelineView(.animation) { timeline in
                    MetalSubtitleTimelineView(
                        renderData: metalRenderData(
                            item: activeItem,
                            end: activeSlapEnd(for: activeItem, at: timeline.date),
                            compact: usesCompactLOD
                        )
                    )
                }
                .frame(width: viewWidth, height: renderHeight)
                .offset(x: viewportOriginX)
                .allowsHitTesting(false)
            }

            // This surface contains only the blocks currently being manipulated,
            // overlap diagnostics and the marquee. Pointer movement never redraws
            // the static text/block surface.
            MetalSubtitleTimelineView(
                renderData: dynamicMetalRenderData(
                    itemIDs: dynamicIDs,
                    compact: usesCompactLOD
                )
            )
            .frame(width: viewWidth, height: renderHeight)
            .offset(x: viewportOriginX)
            .allowsHitTesting(false)

            interactionOverlay(for: drawnItems)
        }
        .coordinateSpace(name: subtitleBlocksCoordinateSpaceName)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .clipped()
        .sheet(isPresented: $isEditingText) {
            SubtitleTextEditSheet(
                title: String(localized: "编辑字幕内容"),
                text: $editingText,
                isPresented: $isEditingText
            ) {
                if let editingItemID {
                    project.updateSubtitleText(id: editingItemID, text: editingText)
                }
            }
        }
        .alert("更改显示时间", isPresented: $isEditingTime) {
            TextField("起始时间，例如 01:23.45", text: $editingStartText)
            TextField("结束时间，例如 01:25.20", text: $editingEndText)
            Button("确定") { saveEditingTime() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("可输入秒数、MM:SS 或 HH:MM:SS")
        }
        .stropheOnChange(of: isEditingText) { project.isEditingText = $0 }
        .stropheOnChange(of: isEditingTime) { project.isEditingText = $0 }
        .onDisappear { stopMarqueeAutoScroll() }
    }

    private var dynamicDragItemIDs: Set<UUID> {
        if activeDragEdge != nil, let activeDragItemID {
            return [activeDragItemID]
        }
        return movingItemIDs
    }

    private func metalRenderData(
        item: SubtitleItem,
        end: Double,
        compact: Bool
    ) -> MetalTimelineFrameRenderData {
        guard let start = item.startTime else { return .empty }
        return MetalTimelineFrameRenderData(
            viewportSize: CGSize(width: viewWidth, height: blockY + blockHeight + 10),
            blocks: [metalBlock(item: item, start: start, end: end, compact: compact)],
            overlapRects: [],
            marqueeRect: nil
        )
    }

    private func dynamicMetalRenderData(
        itemIDs: Set<UUID>,
        compact: Bool
    ) -> MetalTimelineFrameRenderData {
        let draggedBlocks = itemIDs.compactMap { renderModel.item(id: $0) }.compactMap { item -> MetalTimelineBlockRenderData? in
            guard let start = item.startTime else { return nil }
            let end = item.endTime ?? (start + 0.1)
            let times = displayedTimes(for: item, start: start, end: end)
            guard times.end >= renderRange.lowerBound, times.start <= renderRange.upperBound else { return nil }
            return metalBlock(item: item, start: times.start, end: times.end, compact: compact)
        }

        let viewportOriginX = CGFloat(visibleStartTime * pixelsPerSecond)
        let overlaps = renderModel.timelineIndex.overlappingIntervals.compactMap { interval -> CGRect? in
            guard interval.end >= renderRange.lowerBound, interval.start <= renderRange.upperBound else { return nil }
            return CGRect(
                x: CGFloat(interval.start * pixelsPerSecond) - viewportOriginX,
                y: blockY,
                width: max(1, CGFloat((interval.end - interval.start) * pixelsPerSecond)),
                height: blockHeight
            )
        }

        let marquee: CGRect?
        if let start = marqueeStart, let current = marqueeCurrent {
            marquee = CGRect(
                x: min(start, current) - viewportOriginX,
                y: blockY - 1,
                width: max(1, abs(current - start)),
                height: blockHeight + 2
            )
        } else {
            marquee = nil
        }

        return MetalTimelineFrameRenderData(
            viewportSize: CGSize(width: viewWidth, height: blockY + blockHeight + 10),
            blocks: draggedBlocks,
            overlapRects: overlaps,
            marqueeRect: marquee
        )
    }

    private func metalBlock(
        item: SubtitleItem,
        start: Double,
        end: Double,
        compact: Bool
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

        return MetalTimelineBlockRenderData(
            id: item.id,
            rect: CGRect(
                x: CGFloat(start * pixelsPerSecond) - viewportOriginX,
                y: blockY,
                width: max(4, CGFloat((end - start) * pixelsPerSecond)),
                height: blockHeight
            ),
            fillColor: groupColor.withAlpha(fillAlpha),
            strokeColor: (isSelected ? Color.yellow.resolvedRGBA : groupColor).withAlpha(opacity),
            textColor: isSelected ? .white.withAlpha(opacity) : primary,
            markerColor: isSelected ? .white.withAlpha(opacity) : groupColor.withAlpha(opacity),
            strokeWidth: isSelected ? 2 : 1,
            isLocked: isLocked,
            hasIndependentPresentation: item.hasIndependentPresentation,
            text: item.text,
            isCompact: compact
        )
    }

    @ViewBuilder
    private func interactionOverlay(for items: [SubtitleItem]) -> some View {
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
                    let newID = hitTest(at: location)?.item.id
                    if contextItemID != newID { contextItemID = newID }
                case .ended:
                    break
                }
            }
            .contextMenu {
                if let contextItem { blockContextMenu(for: contextItem) }
            }
        #else
        ZStack {
            // Blank timeline space remains owned by the horizontal ScrollView. Only
            // taps are handled here, so a pan that starts between blocks still scrolls.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { handleTap(at: $0) }

            // The one drag recognizer is restricted to the union of visible block
            // rectangles. This keeps centralized hit testing without stealing all
            // iOS ScrollView pans.
            Color.clear
                .contentShape(SubtitleBlockHitShape(rects: interactionRects(for: items)))
                .gesture(blockDragGesture)
                .onTapGesture(coordinateSpace: .local) { handleTap(at: $0) }
                .simultaneousGesture(
                    SpatialTapGesture(count: 2, coordinateSpace: .local)
                        .onEnded { handleDoubleTap(at: $0.location) }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            let newID = hitTest(at: value.startLocation)?.item.id
                            if contextItemID != newID { contextItemID = newID }
                        }
                )
                .contextMenu {
                    if let contextItem { blockContextMenu(for: contextItem) }
                }
        }
        #endif
    }

    private func interactionRects(for items: [SubtitleItem]) -> [CGRect] {
        items.compactMap { item in
            guard let start = item.startTime else { return nil }
            var end = item.endTime ?? (start + 0.1)
            if item.id == renderModel.activeSlapSubtitleID {
                end = activeSlapEnd(for: item, at: .now)
            }
            let displayed = displayedTimes(for: item, start: start, end: end)
            return CGRect(
                x: CGFloat(displayed.start * pixelsPerSecond),
                y: blockY,
                width: max(4, CGFloat((displayed.end - displayed.start) * pixelsPerSecond)),
                height: blockHeight
            )
        }
    }

    private func displayedTimes(for item: SubtitleItem, start: Double, end: Double) -> (start: Double, end: Double) {
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

    private func activeSlapEnd(for item: SubtitleItem, at date: Date) -> Double {
        guard let start = item.startTime else { return item.endTime ?? 0 }
        let rawTime = project.isScrubbing
            ? project.currentTime
            : project.referenceTime + date.timeIntervalSince(project.referenceDate) * project.playbackRate
        let finiteTime = rawTime.isFinite ? rawTime : project.currentTime
        return max(start + minimumFrameDuration, min(workspaceDuration, finiteTime))
    }

    private var minimumFrameDuration: Double {
        project.videoFrameRate > 0 ? 1.0 / project.videoFrameRate : 0.1
    }

    // MARK: Centralized hit testing and gestures

    private struct BlockHit {
        let item: SubtitleItem
        let edge: TimelineInteractionLayer.Edge?
    }

    private func hitTest(at location: CGPoint) -> BlockHit? {
        guard location.y >= blockY, location.y <= blockY + blockHeight else { return nil }
        let time = Double(location.x) / pixelsPerSecond
        let visualTolerance = 4.0 / pixelsPerSecond
        let candidates = renderModel.visibleItems(
            in: max(0, time - visualTolerance)...(time + visualTolerance)
        )

        for item in candidates.reversed() {
            guard let start = item.startTime else { continue }
            var end = item.endTime ?? (start + 0.1)
            if item.id == renderModel.activeSlapSubtitleID {
                end = activeSlapEnd(for: item, at: .now)
            }
            let rect = CGRect(
                x: CGFloat(start * pixelsPerSecond),
                y: blockY,
                width: max(4, CGFloat((end - start) * pixelsPerSecond)),
                height: blockHeight
            )
            guard rect.contains(location) else { continue }

            let handleWidth = min(8, max(2, rect.width * 0.5))
            let edge: TimelineInteractionLayer.Edge?
            if location.x <= rect.minX + handleWidth {
                edge = .left
            } else if location.x >= rect.maxX - handleWidth {
                edge = .right
            } else {
                edge = nil
            }
            return BlockHit(item: item, edge: edge)
        }
        return nil
    }

    private var blockDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in handleDragChanged(value) }
            .onEnded { value in handleDragEnded(value) }
    }

    private func handleDragChanged(_ value: DragGesture.Value) {
        guard renderModel.editingMode == .selection else { return }

        if case .none = dragMode {
            beginDrag(at: value.startLocation)
        }

        switch dragMode {
        case .move(let itemID, let initialStart, let initialEnd):
            let delta = Double(value.translation.width) / pixelsPerSecond
            let startSnap = findBestSnap(for: initialStart + delta, ignoring: itemID)
            let endSnap = findBestSnap(for: initialEnd + delta, ignoring: itemID)
            if let startSnap {
                activeDragDelta = startSnap - initialStart
                triggerHapticFeedbackIfNeeded()
            } else if let endSnap {
                activeDragDelta = endSnap - initialEnd
                triggerHapticFeedbackIfNeeded()
            } else {
                activeDragDelta = delta
                isSnapped = false
            }

        case .leftEdge(let itemID, let initialStart, _):
            let delta = Double(value.translation.width) / pixelsPerSecond
            if let snap = findBestSnap(for: initialStart + delta, ignoring: itemID) {
                activeDragDelta = snap - initialStart
                triggerHapticFeedbackIfNeeded()
            } else {
                activeDragDelta = delta
                isSnapped = false
            }

        case .rightEdge(let itemID, _, let initialEnd):
            let delta = Double(value.translation.width) / pixelsPerSecond
            if let snap = findBestSnap(for: initialEnd + delta, ignoring: itemID) {
                activeDragDelta = snap - initialEnd
                triggerHapticFeedbackIfNeeded()
            } else {
                activeDragDelta = delta
                isSnapped = false
            }

        case .marquee:
            if marqueeCurrent != value.location.x {
                marqueeCurrent = value.location.x
            }
            updateSelectionForMarquee()
            ensureMarqueeAutoScrollTask()

        case .ignored, .none:
            break
        }
    }

    private func beginDrag(at location: CGPoint) {
        if let hit = hitTest(at: location) {
            let item = hit.item
            guard !isLocked(item) else {
                dragMode = .ignored
                return
            }

            #if os(iOS)
            if hit.edge == nil, !renderModel.selectedIDs.contains(item.id) {
                dragMode = .ignored
                return
            }
            #endif

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
            activeDragItemID = item.id
            activeDragEdge = hit.edge

            if let edge = hit.edge {
                dragMode = edge == .left
                    ? .leftEdge(itemID: item.id, initialStart: start, initialEnd: end)
                    : .rightEdge(itemID: item.id, initialStart: start, initialEnd: end)
            } else {
                movingItemIDs = Set(project.items.lazy.filter {
                    project.selectedIDs.contains($0.id) && !project.isLockedForEditing($0)
                }.map(\.id))
                dragMode = .move(itemID: item.id, initialStart: start, initialEnd: end)
            }
            return
        }

        #if os(macOS)
        marqueeStart = location.x
        marqueeCurrent = location.x
        dragMode = .marquee
        updateSelectionForMarquee()
        ensureMarqueeAutoScrollTask()
        #else
        dragMode = .ignored
        #endif
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        defer { resetDragState() }

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
            project.moveSelectedBlocks(by: activeDragDelta)
        case .marquee:
            marqueeCurrent = value.location.x
            updateSelectionForMarquee()
        case .ignored, .none:
            break
        }
    }

    private func resetDragState() {
        stopMarqueeAutoScroll()
        dragMode = .none
        activeDragItemID = nil
        activeDragEdge = nil
        activeDragDelta = 0
        movingItemIDs.removeAll()
        isSnapped = false
        marqueeStart = nil
        marqueeCurrent = nil
    }

    private func findBestSnap(for time: Double, ignoring itemID: UUID) -> Double? {
        let threshold = (isSnapped ? 10.0 : 6.0) / pixelsPerSecond
        var best: Double?
        var bestDistance = Double.infinity

        let playheadDistance = abs(project.currentTime - time)
        if playheadDistance <= threshold {
            best = project.currentTime
            bestDistance = playheadDistance
        }

        if let blockSnap = renderModel.timelineIndex.nearestSnapPoint(to: time, ignoring: itemID) {
            let distance = abs(blockSnap - time)
            if distance <= threshold, distance < bestDistance {
                best = blockSnap
            }
        }
        return best
    }

    private func handleTap(at location: CGPoint) {
        guard renderModel.editingMode == .selection else { return }
        guard let item = hitTest(at: location)?.item else {
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

    private func handleDoubleTap(at location: CGPoint) {
        guard let item = hitTest(at: location)?.item, !isLocked(item) else { return }
        contextItemID = item.id
        beginEditingText(item)
    }

    private var commandKeyIsPressed: Bool {
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

    private func isInActiveGroup(_ item: SubtitleItem) -> Bool {
        renderModel.group(for: item)?.id == renderModel.activeGroupID
    }

    private func isLocked(_ item: SubtitleItem) -> Bool {
        item.isLocked || renderModel.group(for: item)?.isLocked == true
    }

    // MARK: Marquee auto-scroll

    private func updateSelectionForMarquee() {
        guard let startX = marqueeStart, let currentX = marqueeCurrent else { return }
        let minTime = Double(min(startX, currentX)) / pixelsPerSecond
        let maxTime = Double(max(startX, currentX)) / pixelsPerSecond
        guard let activeGroupID = renderModel.activeGroupID else {
            if !project.selectedIDs.isEmpty { project.selectedIDs.removeAll() }
            return
        }

        let newSelection = Set(
            renderModel.visibleItems(in: minTime...maxTime)
                .filter { renderModel.group(for: $0)?.id == activeGroupID }
                .map(\.id)
        )
        if project.selectedIDs != newSelection {
            project.selectedIDs = newSelection
        }
        let isMultiSelecting = newSelection.count > 1
        if project.isSubtitleMultiSelecting != isMultiSelecting {
            project.isSubtitleMultiSelecting = isMultiSelecting
        }
    }

    private func ensureMarqueeAutoScrollTask() {
        guard marqueeAutoScrollTask == nil else { return }
        marqueeAutoScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                performMarqueeAutoScrollStep()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopMarqueeAutoScroll() {
        marqueeAutoScrollTask?.cancel()
        marqueeAutoScrollTask = nil
    }

    private func performMarqueeAutoScrollStep() {
        guard marqueeStart != nil, let currentX = marqueeCurrent else { return }
        guard pixelsPerSecond.isFinite, pixelsPerSecond > 0 else { return }
        guard viewWidth.isFinite, viewWidth > 0 else { return }

        let duration = workspaceDuration.isFinite ? max(0, workspaceDuration) : 0
        let visibleDuration = Double(viewWidth) / pixelsPerSecond
        let maxStartTime = max(0, duration - visibleDuration)
        guard maxStartTime > 0 else { return }

        let visibleStartX = CGFloat(scrollPageStartTime * pixelsPerSecond)
        let visibleEndX = visibleStartX + viewWidth
        let leftDistance = currentX - visibleStartX
        let rightDistance = visibleEndX - currentX
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
        marqueeCurrent = currentX + actualDeltaPixels
        updateSelectionForMarquee()
    }

    // MARK: Editing and context menu

    @ViewBuilder
    private func blockContextMenu(for item: SubtitleItem) -> some View {
        let locked = isLocked(item)

        Button {
            if !project.selectedIDs.contains(item.id) { project.selectedIDs.insert(item.id) }
            project.isSubtitleMultiSelecting = true
        } label: {
            Label(String(localized: "多选字幕块"), systemImage: "checklist")
        }

        Button {
            guard let groupID = renderModel.group(for: item)?.id else { return }
            project.selectedIDs = Set(renderModel.items.filter {
                renderModel.group(for: $0)?.id == groupID
            }.map(\.id))
            project.isSubtitleMultiSelecting = project.selectedIDs.count > 1
        } label: {
            Label(String(localized: "选择同组全部"), systemImage: "checkmark.square.stack")
        }

        Divider()

        Button { beginEditingText(item) } label: {
            Label(String(localized: "编辑内容"), systemImage: "pencil")
        }
        .disabled(locked)

        Button { beginEditingTime(item) } label: {
            Label(String(localized: "更改显示时间"), systemImage: "clock")
        }
        .disabled(locked)

        Menu {
            ForEach(renderModel.sortedGroups) { group in
                Button {
                    if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                        project.assignSelectedSubtitles(toGroup: group.id)
                    } else {
                        project.assignSubtitle(id: item.id, toGroup: group.id)
                    }
                } label: {
                    Label(
                        group.name,
                        systemImage: item.groupID == group.id ? "checkmark.circle.fill" : "circle"
                    )
                }
            }
        } label: {
            Label(String(localized: "移动到分组"), systemImage: "square.stack.3d.up")
        }
        .disabled(locked)

        Menu {
            Button {
                if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                    project.setSelectedSubtitleStyleOverride(styleID: nil)
                } else {
                    project.followGroupStyle(id: item.id)
                }
            } label: {
                Label(
                    String(localized: "跟随小组样式"),
                    systemImage: item.hasIndependentPresentation ? "link" : "checkmark.circle.fill"
                )
            }
            .disabled(!item.hasIndependentPresentation)

            if !renderModel.styles.isEmpty {
                Divider()
                ForEach(renderModel.styles) { style in
                    Button {
                        if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                            project.setSelectedSubtitleStyleOverride(styleID: style.id)
                        } else {
                            project.setSubtitleStyleOverride(id: item.id, styleID: style.id)
                        }
                    } label: {
                        Label(
                            style.name,
                            systemImage: item.styleID == style.id ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            }
        } label: {
            Label(String(localized: "设定样式"), systemImage: "textformat")
        }
        .disabled(locked)

        Button {
            NotificationCenter.default.post(name: .stropheStartSubtitleTranslation, object: item.id)
        } label: {
            Label(String(localized: "从这里开始翻译"), systemImage: "character.bubble")
        }

        Divider()

        Button(role: .destructive) { project.deleteSubtitle(id: item.id) } label: {
            Label(String(localized: "删除字幕"), systemImage: "trash")
        }
        .disabled(locked)
    }

    private func beginEditingText(_ item: SubtitleItem) {
        editingItemID = item.id
        editingText = project.items.first(where: { $0.id == item.id })?.text ?? item.text
        isEditingText = true
    }

    private func beginEditingTime(_ item: SubtitleItem) {
        guard let start = item.startTime else { return }
        editingItemID = item.id
        editingStartText = formatEditableTime(start)
        editingEndText = formatEditableTime(item.endTime ?? start + 0.1)
        isEditingTime = true
    }

    private func saveEditingTime() {
        guard let editingItemID,
              let start = parseEditableTime(editingStartText),
              let end = parseEditableTime(editingEndText) else { return }
        project.updateSubtitleTime(id: editingItemID, newStartTime: start, newEndTime: end)
    }

    private func formatEditableTime(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let totalSeconds = Int(clamped)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let wholeSeconds = totalSeconds % 60
        let centiseconds = Int(((clamped - Double(totalSeconds)) * 100).rounded())
        return hours > 0
            ? String(format: "%d:%02d:%02d.%02d", hours, minutes, wholeSeconds, centiseconds)
            : String(format: "%02d:%02d.%02d", minutes, wholeSeconds, centiseconds)
    }

    private func parseEditableTime(_ raw: String) -> TimeInterval? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty else { return nil }
        let parts = normalized.split(separator: ":").map(String.init)
        if parts.count == 1 {
            return Double(parts[0]).map { max(0, $0) }
        }

        var total = 0.0
        for (index, part) in parts.reversed().enumerated() {
            guard let value = Double(part) else { return nil }
            total += value * pow(60, Double(index))
        }
        return max(0, total)
    }

    private func triggerHapticFeedbackIfNeeded() {
        guard !isSnapped else { return }
        isSnapped = true
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        #elseif os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}
