//
//  SubtitleBlocksLayer.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/17.
//

import SwiftUI

// MARK: - 字幕块显示与交互层
struct SubtitleBlocksLayer: View {
    @ObservedObject var project: SubtitleProject
    let pixelsPerSecond: Double
    let smoothTime: Double
    let scrollPageStartTime: Double
    let viewWidth: CGFloat
    
    private var visibleStartTime: Double {
        max(0, scrollPageStartTime - visiblePadding)
    }
    
    private var visibleEndTime: Double {
        scrollPageStartTime + viewWidth / pixelsPerSecond + visiblePadding
    }
    
    private var visiblePadding: Double {
        viewWidth / pixelsPerSecond * 0.3
    }
    
    private var visibleItems: [SubtitleItem] {
        project.items.filter { item in
            if item.id == project.activeSlapSubtitleID { return true }
            guard let start = item.startTime else { return false }
            let end = item.endTime ?? (start + 0.1)
            return end >= visibleStartTime && start <= visibleEndTime
        }
    }
    
    private var visibleOverlaps: [SubtitleProject.OverlapInterval] {
        project.overlappingIntervals.filter { interval in
            interval.end >= visibleStartTime && interval.start <= visibleEndTime
        }
    }
    
    // 框选状态
    @State private var marqueeStart: CGFloat? = nil
    @State private var marqueeCurrent: CGFloat? = nil
    
    var body: some View {
        ZStack(alignment: .leading) {
            // 背景透明接收板：框选操作与点击空白处取消选中
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    project.selectedIDs.removeAll()
                }
                #if os(macOS)
                .gesture(marqueeGesture)
                #endif
            
            ZStack(alignment: .leading) {
                ForEach(visibleItems) { item in
                    if let start = item.startTime {
                        let rawEnd = item.endTime ?? (start + 0.1)
                        // 💡 如果当前字幕块是正在被拍打的活跃字幕块，我们使用高精度的 smoothTime 实时延伸，画出丝滑生长效果！
                        let displayEnd = (project.activeSlapSubtitleID == item.id)
                            ? max(start + 0.1, smoothTime)
                            : rawEnd
                        
                        InteractiveSubtitleBlock(
                            item: item,
                            start: start,
                            end: displayEnd,
                            pixelsPerSecond: pixelsPerSecond,
                            project: project
                        )
                    }
                }
            }
            
            // ── Overlap diagnostic highlights layer ──────────────────
            ForEach(visibleOverlaps, id: \.self) { interval in
                OverlapStripesView()
                    .frame(width: CGFloat((interval.end - interval.start) * pixelsPerSecond), height: 30)
                    .offset(x: CGFloat(interval.start * pixelsPerSecond), y: 35)
                    .allowsHitTesting(false) // 允许鼠标事件穿透，确保用户依然可以拖动字幕块！
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
                    .offset(x: minX, y: 34)
            }
        }
    }
    
    // 智能多端框选手势：Mac/Apple Pencil 直接框选，iPhone/iPad 触控需长按 0.3s 触发以防与横向滚动冲突
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
    
    // 计算框选碰撞，更新被选中的字幕块集合
    private func updateSelectionForMarquee() {
        guard let startX = marqueeStart, let currentX = marqueeCurrent else { return }
        let minTime = Double(min(startX, currentX)) / pixelsPerSecond
        let maxTime = Double(max(startX, currentX)) / pixelsPerSecond
        
        var newSelected = Set<UUID>()
        for item in project.items {
            if let start = item.startTime, let end = item.endTime {
                // 如果字幕块与选框范围相交，则被框选中
                if start <= maxTime && end >= minTime {
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
                    // 循环生成斜线：起点在上方，终点在下方，产生向右倾斜的斜线
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
