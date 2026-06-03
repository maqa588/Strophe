//
//  SubtitleBlocksLayer.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/17.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

let subtitleBlocksCoordinateSpaceName = "subtitleBlocksCoordinateSpace"

// MARK: - 字幕块显示与交互层
struct SubtitleBlocksLayer: View {
    @ObservedObject var project: SubtitleProject
    let pixelsPerSecond: Double
    let smoothTime: Double
    let visibleStartTime: Double
    let viewWidth: CGFloat
    
    private var renderStartTime: Double {
        max(0, visibleStartTime - visiblePadding)
    }
    
    private var renderEndTime: Double {
        visibleStartTime + Double(viewWidth) / pixelsPerSecond + visiblePadding
    }
    
    private var visiblePadding: Double {
        Double(viewWidth) / pixelsPerSecond * 0.3
    }
    
    private var visibleItems: [SubtitleItem] {
        var items = project.timelineIndex.visibleItems(in: renderStartTime...renderEndTime)
        if let id = project.activeSlapSubtitleID, !items.contains(where: { $0.id == id }) {
            if let slapItem = project.items.first(where: { $0.id == id }) {
                items.append(slapItem)
            }
        }
        return items
    }
    
    private var visibleOverlaps: [SubtitleProject.OverlapInterval] {
        project.overlappingIntervals.filter { interval in
            interval.end >= renderStartTime && interval.start <= renderEndTime
        }
    }
    
    // 框选和拖拽状态
    @State private var marqueeStart: CGFloat? = nil
    @State private var marqueeCurrent: CGFloat? = nil
    
    @State private var activeDragItemID: UUID? = nil
    @State private var activeDragEdge: TimelineInteractionLayer.Edge? = nil
    @State private var activeDragDelta: Double = 0
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    project.selectedIDs.removeAll()
                    project.isSubtitleMultiSelecting = false
                }
                #if os(macOS)
                .gesture(marqueeGesture)
                #endif
            
            ZStack(alignment: .topLeading) {
                if visibleItems.count > 150 {
                    // Compact LOD Mode
                    Canvas { context, size in
                        let blockHeight: CGFloat = 30
                        let blockY: CGFloat = 80
                        for item in visibleItems {
                            let group = project.subgroup(for: item)
                            let groupColor = group?.color ?? Color.stropheBlue
                            let isSelected = project.selectedIDs.contains(item.id)
                            
                            guard let start = item.startTime else { continue }
                            let rawEnd = item.endTime ?? (start + 0.1)
                            let displayEnd = (project.activeSlapSubtitleID == item.id) ? max(start + 0.1, smoothTime) : rawEnd
                            
                            var currentStart = start
                            var currentEnd = displayEnd
                            
                            if item.id == activeDragItemID {
                                if activeDragEdge == .left {
                                    currentStart += activeDragDelta
                                } else if activeDragEdge == .right {
                                    currentEnd += activeDragDelta
                                } else {
                                    currentStart += activeDragDelta
                                    currentEnd += activeDragDelta
                                }
                            } else if activeDragEdge == nil && activeDragItemID != nil && project.selectedIDs.contains(item.id) {
                                currentStart += activeDragDelta
                                currentEnd += activeDragDelta
                            }
                            
                            let x = CGFloat(currentStart * pixelsPerSecond)
                            let width = CGFloat((currentEnd - currentStart) * pixelsPerSecond)
                            let rect = CGRect(x: x, y: blockY, width: max(1, width), height: blockHeight)
                            
                            let fill = isSelected ? groupColor.opacity(0.62) : groupColor.opacity(0.28)
                            let stroke = isSelected ? Color.yellow : groupColor
                            
                            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(fill))
                            context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(stroke), lineWidth: isSelected ? 2 : 1)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                } else {
                    ZStack(alignment: .topLeading) {
                        ForEach(visibleItems) { item in
                            if let start = item.startTime {
                                let rawEnd = item.endTime ?? (start + 0.1)
                                let displayEnd = (project.activeSlapSubtitleID == item.id)
                                    ? max(start + 0.1, smoothTime)
                                    : rawEnd
                                
                                InteractiveSubtitleBlock(
                                    item: item,
                                    start: start,
                                    end: displayEnd,
                                    pixelsPerSecond: pixelsPerSecond,
                                    project: project,
                                    activeDragItemID: $activeDragItemID,
                                    activeDragEdge: $activeDragEdge,
                                    activeDragDelta: $activeDragDelta
                                )
                            }
                        }
                    }
                    .padding(.top, 80)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            
            // ── Overlap diagnostic highlights layer ──────────────────
            ForEach(visibleOverlaps, id: \.self) { interval in
                OverlapStripesView()
                    .frame(width: CGFloat((interval.end - interval.start) * pixelsPerSecond), height: 30)
                    .offset(x: CGFloat(interval.start * pixelsPerSecond), y: 80)
                    .allowsHitTesting(false)
            }
            
            // 框选虚线选框
            if let startX = marqueeStart, let currentX = marqueeCurrent {
                let minX = min(startX, currentX)
                let maxX = max(startX, currentX)
                let width = max(1, maxX - minX)
                
                Rectangle()
                    .fill(Color.stropheBlue.opacity(0.15))
                    .overlay(
                        Rectangle()
                            .stroke(Color.stropheBlue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 4]))
                    )
                    .frame(width: width, height: 32)
                    .offset(x: minX, y: 79)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: subtitleBlocksCoordinateSpaceName)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var marqueeGesture: some Gesture {
        let drag = DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard project.editingMode == .selection else { return }
                if marqueeStart == nil {
                    marqueeStart = value.startLocation.x
                }
                marqueeCurrent = value.location.x
                updateSelectionForMarquee()
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeCurrent = nil
            }
        
        #if os(iOS)
        // 移动端：长按 0.3 秒后，手指拖拽可以框选
        return LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: drag)
            .onChanged { value in
                switch value {
                case .second(true, let dragVal):
                    if let dragVal = dragVal {
                        if marqueeStart == nil {
                            marqueeStart = dragVal.startLocation.x
                        }
                        marqueeCurrent = dragVal.location.x
                        updateSelectionForMarquee()
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeCurrent = nil
            }
        #else
        // macOS 端：鼠标左键直接拖拽即可框选
        return drag
        #endif
    }
    
    private func updateSelectionForMarquee() {
        guard let startX = marqueeStart, let currentX = marqueeCurrent else { return }
        let minTime = Double(min(startX, currentX)) / pixelsPerSecond
        let maxTime = Double(max(startX, currentX)) / pixelsPerSecond
        let activeGroupID = StyleAndGroupStore.shared.activeGroupID
        
        var newSelected = Set<UUID>()
        for item in project.items {
            if let start = item.startTime, let end = item.endTime {
                if start <= maxTime && end >= minTime,
                   project.subgroup(for: item)?.id == activeGroupID {
                    newSelected.insert(item.id)
                }
            }
        }
        project.selectedIDs = newSelected
    }
}

// MARK: - Overlap Diagnostic Stripes View
struct OverlapStripesView: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 8 // 斜线间距
            let lineW: CGFloat = 1.5
            
            context.stroke(
                Path { path in
                    for x in stride(from: -size.height, to: size.width + size.height, by: step) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    }
                },
                with: .color(.pink.opacity(0.6)),
                lineWidth: lineW
            )
        }
        .background(Color.pink.opacity(0.15))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.pink.opacity(0.8), lineWidth: 1.0)
        )
    }
}
