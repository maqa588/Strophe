//
//  InteractiveSubtitleBlock.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import SwiftUI

struct InteractiveSubtitleBlock: View {
    let item: SubtitleItem
    let start: TimeInterval
    let end: TimeInterval
    let pixelsPerSecond: Double
    @ObservedObject var project: SubtitleProject
    
    @State private var dragOffset: CGFloat = 0
    @State private var edgeDragOffset: CGFloat = 0
    @State private var draggingEdge: Edge? = nil
    
    // 磁力吸附与物理反馈状态
    @State private var isSnappedLeft = false
    @State private var isSnappedRight = false
    @State private var isSnappedCenter = false
    @State private var snappedTime: Double? = nil
    
    // 文字编辑弹窗控制
    @State private var isEditingText = false
    @State private var editingText = ""
    
    enum Edge { case left, right }
    
    private func triggerHapticFeedback() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        #elseif os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }
    
    var body: some View {
        let baseWidth = CGFloat((end - start) * pixelsPerSecond)
        let baseX = CGFloat(start * pixelsPerSecond)
        
        let currentWidth = max(4, baseWidth + (draggingEdge == .right ? edgeDragOffset : (draggingEdge == .left ? -edgeDragOffset : 0)))
        let currentX = baseX + (draggingEdge == .left ? edgeDragOffset : 0) + (draggingEdge == nil ? dragOffset : 0)
        
        let isSelected = project.selectedIDs.contains(item.id)
        
        ZStack {
            // 主体块
            Text(item.text)
                .font(.system(size: 9))
                .padding(.horizontal, 8)
                .frame(width: currentWidth, height: 30)
                .background(isSelected ? Color.accentColor.opacity(0.55) : Color.accentColor.opacity(0.3))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.yellow : Color.accentColor, lineWidth: isSelected ? 2 : 1)
                )
            
            // 边缘拉伸把手（仅在选择模式下激活）
            if project.editingMode == .selection {
                HStack(spacing: 0) {
                    // 左拉把手
                    Rectangle()
                        .fill(Color.white.opacity(0.01))
                        .frame(width: 8, height: 30)
                        .contentShape(Rectangle())
                        #if os(macOS)
                        .onHover { hover in
                            if hover { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        #endif
                        .gesture(
                            DragGesture(coordinateSpace: .global)
                                .onChanged { value in
                                    draggingEdge = .left
                                    let rawProposedStart = start + Double(value.translation.width / pixelsPerSecond)
                                    let snapCandidates = project.items.filter { $0.id != item.id }.flatMap { [$0.startTime, $0.endTime] }.compactMap { $0 }
                                    
                                    let playheadTime = project.currentTime
                                    let playheadDistance = abs(playheadTime - rawProposedStart)
                                    
                                    var closestBlockSnap: Double? = nil
                                    var blockDistance = Double.infinity
                                    if let closest = snapCandidates.min(by: { abs($0 - rawProposedStart) < abs($1 - rawProposedStart) }) {
                                        closestBlockSnap = closest
                                        blockDistance = abs(closest - rawProposedStart)
                                    }
                                    
                                    let activeThreshold = isSnappedLeft ? (20.0 / pixelsPerSecond) : (10.0 / pixelsPerSecond)
                                    
                                    let isPlayheadInThreshold = playheadDistance <= activeThreshold
                                    let isBlockInThreshold = blockDistance <= activeThreshold
                                    
                                    var closestSnap: Double? = nil
                                    if isPlayheadInThreshold && isBlockInThreshold {
                                        // Competition: Prioritize playhead if they are very close, otherwise take the closer one
                                        let difference = abs(playheadTime - closestBlockSnap!)
                                        let closeProximityThreshold = 3.0 / pixelsPerSecond
                                        if difference <= closeProximityThreshold {
                                            closestSnap = playheadTime
                                        } else {
                                            closestSnap = (playheadDistance < blockDistance) ? playheadTime : closestBlockSnap
                                        }
                                    } else if isPlayheadInThreshold {
                                        closestSnap = playheadTime
                                    } else if isBlockInThreshold {
                                        closestSnap = closestBlockSnap
                                    }
                                    
                                    var matchedSnap: Double? = nil
                                    if let snap = closestSnap {
                                        if !isSnappedLeft {
                                            isSnappedLeft = true
                                            snappedTime = snap
                                            triggerHapticFeedback()
                                        }
                                        matchedSnap = snap
                                    } else {
                                        isSnappedLeft = false
                                        snappedTime = nil
                                    }
                                    
                                    if let snap = matchedSnap {
                                        edgeDragOffset = CGFloat((snap - start) * pixelsPerSecond)
                                    } else {
                                        edgeDragOffset = value.translation.width
                                    }
                                }
                                .onEnded { value in
                                    let delta = edgeDragOffset / pixelsPerSecond
                                    project.updateSubtitleTime(id: item.id, newStartTime: start + delta, newEndTime: end)
                                    edgeDragOffset = 0
                                    isSnappedLeft = false
                                    snappedTime = nil
                                    draggingEdge = nil
                                }
                        )
                    
                    Spacer(minLength: 0)
                    
                    // 右拉把手
                    Rectangle()
                        .fill(Color.white.opacity(0.01))
                        .frame(width: 8, height: 30)
                        .contentShape(Rectangle())
                        #if os(macOS)
                        .onHover { hover in
                            if hover { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        #endif
                        .gesture(
                            DragGesture(coordinateSpace: .global)
                                .onChanged { value in
                                    draggingEdge = .right
                                    let rawProposedEnd = end + Double(value.translation.width / pixelsPerSecond)
                                    let snapCandidates = project.items.filter { $0.id != item.id }.flatMap { [$0.startTime, $0.endTime] }.compactMap { $0 }
                                    
                                    let playheadTime = project.currentTime
                                    let playheadDistance = abs(playheadTime - rawProposedEnd)
                                    
                                    var closestBlockSnap: Double? = nil
                                    var blockDistance = Double.infinity
                                    if let closest = snapCandidates.min(by: { abs($0 - rawProposedEnd) < abs($1 - rawProposedEnd) }) {
                                        closestBlockSnap = closest
                                        blockDistance = abs(closest - rawProposedEnd)
                                    }
                                    
                                    let activeThreshold = isSnappedRight ? (20.0 / pixelsPerSecond) : (10.0 / pixelsPerSecond)
                                    
                                    let isPlayheadInThreshold = playheadDistance <= activeThreshold
                                    let isBlockInThreshold = blockDistance <= activeThreshold
                                    
                                    var closestSnap: Double? = nil
                                    if isPlayheadInThreshold && isBlockInThreshold {
                                        // Competition: Prioritize playhead if they are very close, otherwise take the closer one
                                        let difference = abs(playheadTime - closestBlockSnap!)
                                        let closeProximityThreshold = 3.0 / pixelsPerSecond
                                        if difference <= closeProximityThreshold {
                                            closestSnap = playheadTime
                                        } else {
                                            closestSnap = (playheadDistance < blockDistance) ? playheadTime : closestBlockSnap
                                        }
                                    } else if isPlayheadInThreshold {
                                        closestSnap = playheadTime
                                    } else if isBlockInThreshold {
                                        closestSnap = closestBlockSnap
                                    }
                                    
                                    var matchedSnap: Double? = nil
                                    if let snap = closestSnap {
                                        if !isSnappedRight {
                                            isSnappedRight = true
                                            snappedTime = snap
                                            triggerHapticFeedback()
                                        }
                                        matchedSnap = snap
                                    } else {
                                        isSnappedRight = false
                                        snappedTime = nil
                                    }
                                    
                                    if let snap = matchedSnap {
                                        edgeDragOffset = CGFloat((snap - end) * pixelsPerSecond)
                                    } else {
                                        edgeDragOffset = value.translation.width
                                    }
                                }
                                .onEnded { value in
                                    let delta = edgeDragOffset / pixelsPerSecond
                                    project.updateSubtitleTime(id: item.id, newStartTime: start, newEndTime: end + delta)
                                    edgeDragOffset = 0
                                    isSnappedRight = false
                                    snappedTime = nil
                                    draggingEdge = nil
                                }
                        )
                }
                .frame(width: currentWidth)
            }
        }
        .offset(x: currentX, y: 35)
        // 选中与点击手势
        .onTapGesture {
            project.selectedIDs = [item.id]
        }
        // 双击字幕块自动进入编辑界面
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    editingText = item.text
                    isEditingText = true
                }
        )
        // 拖动平移字幕块手势
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    guard project.editingMode == .selection else { return }
                    if draggingEdge == nil {
                        let rawProposedStart = start + Double(value.translation.width / pixelsPerSecond)
                        let rawProposedEnd = end + Double(value.translation.width / pixelsPerSecond)
                        let snapCandidates = project.items.filter { $0.id != item.id }.flatMap { [$0.startTime, $0.endTime] }.compactMap { $0 }
                        
                        // 1. Find the best snap candidate from other block edges
                        var bestBlockSnapTime: Double? = nil
                        var minBlockDistance = Double.infinity
                        var blockSourceEdge: Edge = .left
                        
                        for candidate in snapCandidates {
                            let distStart = abs(candidate - rawProposedStart)
                            if distStart < minBlockDistance {
                                minBlockDistance = distStart
                                bestBlockSnapTime = candidate
                                blockSourceEdge = .left
                            }
                            let distEnd = abs(candidate - rawProposedEnd)
                            if distEnd < minBlockDistance {
                                minBlockDistance = distEnd
                                bestBlockSnapTime = candidate
                                blockSourceEdge = .right
                            }
                        }
                        
                        // 2. Find the best snap candidate from the playhead
                        let playheadTime = project.currentTime
                        let playheadStartDistance = abs(playheadTime - rawProposedStart)
                        let playheadEndDistance = abs(playheadTime - rawProposedEnd)
                        
                        let minPlayheadDistance = min(playheadStartDistance, playheadEndDistance)
                        let playheadSourceEdge: Edge = (playheadStartDistance < playheadEndDistance) ? .left : .right
                        
                        // 3. Determine active threshold (hysteresis)
                        let activeThreshold = isSnappedCenter ? (20.0 / pixelsPerSecond) : (10.0 / pixelsPerSecond)
                        
                        let isPlayheadInThreshold = minPlayheadDistance <= activeThreshold
                        let isBlockInThreshold = minBlockDistance <= activeThreshold
                        
                        var closestSnap: Double? = nil
                        var snapSourceEdge: Edge = .left
                        
                        if isPlayheadInThreshold && isBlockInThreshold {
                            // Competition: Prioritize playhead if they are very close, otherwise take the closer one
                            let difference = abs(playheadTime - bestBlockSnapTime!)
                            let closeProximityThreshold = 3.0 / pixelsPerSecond
                            if difference <= closeProximityThreshold {
                                closestSnap = playheadTime
                                snapSourceEdge = playheadSourceEdge
                            } else {
                                if minPlayheadDistance < minBlockDistance {
                                    closestSnap = playheadTime
                                    snapSourceEdge = playheadSourceEdge
                                } else {
                                    closestSnap = bestBlockSnapTime
                                    snapSourceEdge = blockSourceEdge
                                }
                            }
                        } else if isPlayheadInThreshold {
                            closestSnap = playheadTime
                            snapSourceEdge = playheadSourceEdge
                        } else if isBlockInThreshold {
                            closestSnap = bestBlockSnapTime
                            snapSourceEdge = blockSourceEdge
                        }
                        
                        var matchedSnap: Double? = nil
                        if let snap = closestSnap {
                            if !isSnappedCenter {
                                isSnappedCenter = true
                                snappedTime = snap
                                triggerHapticFeedback()
                            }
                            matchedSnap = snap
                        } else {
                            isSnappedCenter = false
                            snappedTime = nil
                        }
                        
                        if let snap = matchedSnap {
                            if snapSourceEdge == .left {
                                dragOffset = CGFloat((snap - start) * pixelsPerSecond)
                            } else {
                                dragOffset = CGFloat((snap - end) * pixelsPerSecond)
                            }
                        } else {
                            dragOffset = value.translation.width
                        }
                    }
                }
                .onEnded { value in
                    guard project.editingMode == .selection else { return }
                    if draggingEdge == nil {
                        let delta = dragOffset / pixelsPerSecond
                        project.updateSubtitleTime(id: item.id, newStartTime: start + delta, newEndTime: end + delta)
                        dragOffset = 0
                        isSnappedCenter = false
                        snappedTime = nil
                    }
                }
        )
        // 多平台一致右键/长按菜单
        .contextMenu {
            Button(action: {
                editingText = item.text
                isEditingText = true
            }) {
                Label("编辑内容", systemImage: "pencil")
            }
            
            Button(role: .destructive, action: {
                project.deleteSubtitle(id: item.id)
            }) {
                Label("删除字幕", systemImage: "trash")
            }
        } preview: {
            Text(item.text)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.85))
                .foregroundColor(.white)
                .cornerRadius(6)
        }
        // 原生编辑文本弹框
        .alert("编辑字幕内容", isPresented: $isEditingText) {
            TextField("输入新字幕文本", text: $editingText)
            Button("确定") {
                project.updateSubtitleText(id: item.id, text: editingText)
            }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: isEditingText) { _, newValue in
            project.isEditingText = newValue
        }
    }
}
