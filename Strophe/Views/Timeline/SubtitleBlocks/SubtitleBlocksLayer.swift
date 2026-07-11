//
//  Core state and lifecycle for the Metal-backed subtitle timeline.
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

struct SubtitleBlocksLayer: View {
    // MARK: Inputs

    let project: SubtitleProject
    let pixelsPerSecond: Double
    let visibleStartTime: Double
    let viewWidth: CGFloat
    let workspaceDuration: Double
    @Binding var scrollPageStartTime: Double
    @Binding var trackVerticalScale: CGFloat
    @Binding var trackVerticalOffset: CGFloat

    // MARK: Render state

    @StateObject var renderModel: SubtitleBlocksRenderModel
    @Environment(\.colorScheme) var colorScheme

    // MARK: Selection state

    @State var marqueeStart: CGPoint?
    @State var marqueeCurrent: CGPoint?
    @State var marqueeAutoScrollTask: Task<Void, Never>?

    // MARK: Drag state

    @State var dragMode: BlockDragMode = .none
    @State var activeDragItemID: UUID?
    @State var activeDragEdge: TimelineInteractionLayer.Edge?
    @State var activeDragDelta: Double = 0
    @State var activeDragVerticalDelta: CGFloat = 0
    @State var movingItemIDs: Set<UUID> = []
    @State var dragSnapGroupID: UUID?
    @State var dragSnapLock: DragSnapLock?
    @State var dragTargetGroupID: UUID?
    @State var dragAxisIntent: DragAxisIntent = .undecided
    @State var isLiftDragging = false
    @State var liftAnimationStartDate: Date?
    @State var trackPanStartOffset: CGFloat?
    @State var directTouchMode: DirectTouchMode = .none

    // MARK: Editing state

    @State var contextItemID: UUID?
    @State var hoveredItemID: UUID?
    @State var isPointingAtTrimHandle = false
    @State var editingItemID: UUID?
    @State var editingText = ""
    @State var isEditingText = false
    @State var editingStartText = ""
    @State var editingEndText = ""
    @State var isEditingTime = false
    @State var isShowingMobileBlockActions = false

    // MARK: Interaction constants and value types

    let marqueeAutoScrollEdgeInset: CGFloat = 72
    let marqueeAutoScrollMaxSpeed: CGFloat = 560
    let marqueeAutoScrollFrameInterval: TimeInterval = 1.0 / 60.0

    enum BlockDragMode {
        case move(itemID: UUID, initialStart: Double, initialEnd: Double)
        case leftEdge(itemID: UUID, initialStart: Double, initialEnd: Double)
        case rightEdge(itemID: UUID, initialStart: Double, initialEnd: Double)
        case marquee
        case ignored
        case none
    }

    enum DragSnapAnchor: Hashable {
        case start
        case end
    }

    enum DragAxisIntent {
        case undecided
        case horizontal
        case vertical
    }

    enum DirectTouchMode {
        case blockEdit
        case trackPan
        case none
    }

    struct DragSnapProposal {
        let anchor: DragSnapAnchor
        let initialTime: Double
        let proposedTime: Double
    }

    struct DragSnapLock: Equatable {
        let anchor: DragSnapAnchor
        let targetTime: Double
    }

    init(
        project: SubtitleProject,
        pixelsPerSecond: Double,
        visibleStartTime: Double,
        viewWidth: CGFloat,
        workspaceDuration: Double,
        scrollPageStartTime: Binding<Double>,
        trackVerticalScale: Binding<CGFloat>,
        trackVerticalOffset: Binding<CGFloat>
    ) {
        self.project = project
        self.pixelsPerSecond = pixelsPerSecond
        self.visibleStartTime = visibleStartTime
        self.viewWidth = viewWidth
        self.workspaceDuration = workspaceDuration
        _scrollPageStartTime = scrollPageStartTime
        _trackVerticalScale = trackVerticalScale
        _trackVerticalOffset = trackVerticalOffset
        _renderModel = StateObject(wrappedValue: SubtitleBlocksRenderModel(project: project))
    }

    var visiblePadding: Double {
        Double(viewWidth) / pixelsPerSecond * 0.3
    }

    var renderRange: ClosedRange<Double> {
        let start = max(0, visibleStartTime - visiblePadding)
        let end = visibleStartTime + Double(viewWidth) / pixelsPerSecond + visiblePadding
        return start...end
    }

    var visibleItems: [SubtitleItem] {
        renderModel.visibleItems(in: renderRange).filter {
            renderModel.group(for: $0)?.isOverlayEnabled == true
        }
    }

    var trackGroups: [SubGroupItem] {
        renderModel.sortedGroups.filter(\.isOverlayEnabled)
    }

    var timelineHeight: CGFloat {
        SubtitleTimelineTrackMetrics.totalHeight(trackCount: trackGroups.count)
    }

    var contextItem: SubtitleItem? {
        renderModel.item(id: contextItemID)
    }

    var body: some View {
        let drawnItems = visibleItems
        let activeSlapID = renderModel.activeSlapSubtitleID
        let usesCompactLOD = drawnItems.count > 150
        let dynamicIDs = dynamicDragItemIDs
        let excludedStaticIDs = dynamicIDs.union(activeSlapID.map { [$0] } ?? [])
        let viewportOriginX = CGFloat(visibleStartTime * pixelsPerSecond)
        let renderHeight = timelineHeight

        ZStack(alignment: .topLeading) {
            MetalStaticSubtitleTimelineLayer(
                renderRevision: renderModel.renderRevision,
                items: drawnItems,
                groups: renderModel.groups,
                selectedIDs: renderModel.selectedIDs,
                excludedIDs: excludedStaticIDs,
                trimHandleItemIDs: trimHandleItemIDs,
                pixelsPerSecond: pixelsPerSecond,
                visibleStartTime: visibleStartTime,
                viewWidth: viewWidth,
                trackVerticalScale: trackVerticalScale,
                trackVerticalOffset: trackVerticalOffset,
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
            Group {
                if let liftAnimationStartDate, isLiftDragging {
                    TimelineView(.animation) { timeline in
                        MetalSubtitleTimelineView(
                            renderData: dynamicMetalRenderData(
                                itemIDs: dynamicIDs,
                                compact: usesCompactLOD,
                                liftProgress: liftProgress(
                                    from: liftAnimationStartDate,
                                    at: timeline.date
                                )
                            )
                        )
                    }
                } else {
                    MetalSubtitleTimelineView(
                        renderData: dynamicMetalRenderData(
                            itemIDs: dynamicIDs,
                            compact: usesCompactLOD,
                            liftProgress: 0
                        )
                    )
                }
            }
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
                title: String(localized: "edit_subtitle_content"),
                text: $editingText,
                isPresented: $isEditingText
            ) {
                if let editingItemID {
                    project.updateSubtitleText(id: editingItemID, text: editingText)
                }
            }
        }
        .alert("change_display_time", isPresented: $isEditingTime) {
            TextField("start_time_eg_012345", text: $editingStartText)
            TextField("end_time_eg_012520", text: $editingEndText)
            Button("ok_1") { saveEditingTime() }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("can_enter_seconds_mmss_or")
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingMobileBlockActions) {
            mobileBlockActionsSheet
        }
        #endif
        .stropheOnChange(of: isEditingText) { project.isEditingText = $0 }
        .stropheOnChange(of: isEditingTime) { project.isEditingText = $0 }
        .stropheOnChange(of: renderModel.activeGroupID) { activeGroupID in
            guard let activeGroupID else {
                if !project.selectedIDs.isEmpty { project.selectedIDs.removeAll() }
                return
            }
            let activeSelection = Set(project.selectedIDs.filter { id in
                renderModel.item(id: id).map {
                    renderModel.group(for: $0)?.id == activeGroupID
                } == true
            })
            if activeSelection != project.selectedIDs {
                project.selectedIDs = activeSelection
            }
            contextItemID = nil
            hoveredItemID = nil
        }
        .stropheOnChange(of: trackVerticalScale) { _ in clampTrackViewport() }
        .stropheOnChange(of: trackGroups.count) { _ in clampTrackViewport() }
        .onDisappear {
            stopMarqueeAutoScroll()
            resetTimelineCursor()
        }
    }

    var dynamicDragItemIDs: Set<UUID> {
        if activeDragEdge != nil, let activeDragItemID {
            return [activeDragItemID]
        }
        return movingItemIDs
    }

    var trimHandleItemIDs: Set<UUID> {
        var ids = Set(renderModel.selectedIDs.filter { id in
            renderModel.item(id: id).map(isTimelineEditable) == true
        })
        #if os(macOS)
        if let hoveredItemID,
           renderModel.item(id: hoveredItemID).map(isTimelineEditable) == true {
            ids.insert(hoveredItemID)
        }
        #endif
        return ids
    }
}
