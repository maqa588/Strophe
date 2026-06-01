//
//  InteractiveSubtitleBlock.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct InteractiveSubtitleBlock: View {
    let item: SubtitleItem
    let start: TimeInterval
    let end: TimeInterval
    let pixelsPerSecond: Double
    @ObservedObject var project: SubtitleProject
    @ObservedObject private var store = StyleAndGroupStore.shared
    var onSweepSelectionStart: ((SubtitleItem) -> Void)? = nil
    var onSweepSelectionChange: ((CGFloat) -> Void)? = nil
    var onSweepSelectionEnd: (() -> Void)? = nil
    
    @State private var dragOffset: CGFloat = 0
    @State private var edgeDragOffset: CGFloat = 0
    @State private var draggingEdge: Edge? = nil
    @State private var isSweepSelecting = false
    
    // 磁力吸附与物理反馈状态
    @State private var isSnappedLeft = false
    @State private var isSnappedRight = false
    @State private var isSnappedCenter = false
    @State private var snappedTime: Double? = nil
    
    // 文字编辑弹窗控制
    @State private var isEditingText = false
    @State private var editingText = ""
    @State private var isEditingTime = false
    @State private var editingStartText = ""
    @State private var editingEndText = ""
    @State private var isShowingBlockActions = false
    @State private var popoverMode: BlockActionsMode = .actions
    
    enum Edge { case left, right }
    enum BlockActionsMode { case actions, groups, styles, multiSelect }

    private var isInActiveGroup: Bool {
        project.subgroup(for: item, store: store)?.id == store.activeGroupID
    }

    private var allowsDirectBlockDrag: Bool {
        #if os(iOS)
        return project.selectedIDs.contains(item.id)
        #else
        return true
        #endif
    }

    private var currentGroupID: UUID? {
        project.subgroup(for: item, store: store)?.id
    }

    private var currentGroupItems: [SubtitleItem] {
        guard let currentGroupID else { return [] }
        return project.items
            .filter { (project.subgroup(for: $0, store: store)?.id) == currentGroupID }
            .sorted { lhs, rhs in
                switch (lhs.startTime, rhs.startTime) {
                case let (lhsStart?, rhsStart?):
                    return lhsStart == rhsStart ? lhs.originalIndex < rhs.originalIndex : lhsStart < rhsStart
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.originalIndex < rhs.originalIndex
                }
            }
    }
    
    private func triggerHapticFeedback() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        #elseif os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }

    private func handleTapSelection() {
        #if os(iOS)
        if project.isSubtitleMultiSelecting && isInActiveGroup {
            if project.selectedIDs.contains(item.id) {
                project.selectedIDs.remove(item.id)
                if project.selectedIDs.isEmpty {
                    project.isSubtitleMultiSelecting = false
                }
            } else {
                project.selectedIDs.insert(item.id)
            }
        } else {
            project.selectedIDs = [item.id]
            project.isSubtitleMultiSelecting = false
        }
        #else
        DispatchQueue.main.async {
            if NSEvent.modifierFlags.contains(.command) {
                guard self.isInActiveGroup else { return }
                if self.project.selectedIDs.contains(self.item.id) {
                    self.project.selectedIDs.remove(self.item.id)
                } else {
                    self.project.selectedIDs.insert(self.item.id)
                }
            } else {
                self.project.selectedIDs = [self.item.id]
            }
        }
        #endif
    }

    private func showBlockActions() {
        handleTapSelection()
        popoverMode = .actions
        // Delay slightly to ensure any selection-based layout changes settle
        // before presenting the popover, preventing it from being swallowed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isShowingBlockActions = true
        }
    }
    
    var body: some View {
        let baseWidth = CGFloat((end - start) * pixelsPerSecond)
        let baseX = CGFloat(start * pixelsPerSecond)
        
        let currentWidth = max(4, baseWidth + (draggingEdge == .right ? edgeDragOffset : (draggingEdge == .left ? -edgeDragOffset : 0)))
        
        let effectiveDragOffset: CGFloat = draggingEdge == nil ? (
            project.selectedIDs.contains(item.id) && project.activeDragItemID != nil
            ? CGFloat(project.activeDragDelta * pixelsPerSecond)
            : dragOffset
        ) : 0
        
        let currentX = baseX + (draggingEdge == .left ? edgeDragOffset : 0) + effectiveDragOffset
        
        let isSelected = project.selectedIDs.contains(item.id)
        let group = project.subgroup(for: item, store: store)
        let groupColor = group?.color ?? Color.stropheBlue
        let isLocked = item.isLocked || group?.isLocked == true
        let isDimmed = item.isHidden || group?.isOverlayEnabled == false
        let hasIndependentPresentation = item.hasIndependentPresentation
        
        ZStack {
            // 主体块
            HStack(spacing: 5) {
                if hasIndependentPresentation {
                    Circle()
                        .fill(isSelected ? Color.white : groupColor)
                        .frame(width: 5, height: 5)
                        .help("使用独立样式或独立位置")
                }

                Text(item.text.isEmpty ? " " : item.text)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .help("字幕块或分组已锁定")
                }
            }
            .padding(.horizontal, 8)
            .frame(width: currentWidth, height: 30, alignment: .leading)
            .background(isSelected ? groupColor.opacity(0.62) : groupColor.opacity(0.28))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(4)
            .opacity(isDimmed ? 0.42 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        isSelected ? Color.yellow : groupColor,
                        style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: isLocked ? [4, 3] : [])
                    )
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
                                    guard !isLocked else { return }
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
                                    guard !isLocked else {
                                        edgeDragOffset = 0
                                        draggingEdge = nil
                                        return
                                    }
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
                                    guard !isLocked else { return }
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
                                    guard !isLocked else {
                                        edgeDragOffset = 0
                                        draggingEdge = nil
                                        return
                                    }
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
        .onTapGesture {
            handleTapSelection()
        }
        #if os(iOS)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    showBlockActions()
                }
        )
        #endif
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
                    guard allowsDirectBlockDrag, project.editingMode == .selection, !isSweepSelecting, !isLocked else { return }
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

                        if project.selectedIDs.count > 1 && project.selectedIDs.contains(item.id) {
                            project.activeDragItemID = item.id
                            project.activeDragDelta = Double(dragOffset / pixelsPerSecond)
                        }
                    }
                }
                .onEnded { value in
                    guard allowsDirectBlockDrag, project.editingMode == .selection, !isSweepSelecting, !isLocked else { return }
                    if draggingEdge == nil {
                        let delta = dragOffset / pixelsPerSecond
                        if project.selectedIDs.count > 1 && project.selectedIDs.contains(item.id) {
                            project.moveSelectedBlocks(by: delta)
                        } else {
                            project.updateSubtitleTime(id: item.id, newStartTime: start + delta, newEndTime: end + delta)
                        }
                        dragOffset = 0
                        isSnappedCenter = false
                        snappedTime = nil
                        project.activeDragDelta = 0
                        project.activeDragItemID = nil
                    }
                }
        )
        .popover(isPresented: $isShowingBlockActions, arrowEdge: .bottom) {
            blockActionsPopover
        }
        #if os(macOS)
        .contextMenu {
            macContextMenu
        }
        #endif
        // 原生编辑文本弹框
        .alert("编辑字幕内容", isPresented: $isEditingText) {
            TextField("输入新字幕文本", text: $editingText)
            Button("确定") {
                project.updateSubtitleText(id: item.id, text: editingText)
            }
            Button("取消", role: .cancel) {}
        }
        .alert("更改显示时间", isPresented: $isEditingTime) {
            TextField("起始时间，例如 01:23.45", text: $editingStartText)
            TextField("结束时间，例如 01:25.20", text: $editingEndText)
            Button("确定") {
                saveEditingTime()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("可输入秒数、MM:SS 或 HH:MM:SS")
        }
        .onChange(of: isEditingText) { _, newValue in
            project.isEditingText = newValue
        }
        .onChange(of: isEditingTime) { _, newValue in
            project.isEditingText = newValue
        }
    }

    private var blockActionsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            popoverHeader

            Divider()
                .opacity(0.45)

            switch popoverMode {
            case .actions:
                actionsPage
            case .groups:
                groupsPage
            case .styles:
                stylesPage
            case .multiSelect:
                multiSelectPage
            }
        }
        .buttonStyle(.plain)
        .labelStyle(.titleAndIcon)
        .padding(14)
        .frame(width: popoverMode == .multiSelect ? 340 : 280, alignment: .leading)
        #if os(iOS)
        .presentationCompactAdaptation(.popover)
        #endif
    }

    private var popoverHeader: some View {
        let group = project.subgroup(for: item, store: store)
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(group?.color ?? Color.stropheBlue)
                .frame(width: 5, height: 44)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.text.isEmpty ? String(localized: "待录入字幕") : item.text)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(group?.name ?? String(localized: "未分组"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background((group?.color ?? Color.stropheBlue).opacity(0.18), in: Capsule())

                    Text("\(formatCompactTime(start)) - \(formatCompactTime(end))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var actionsPage: some View {
        let group = project.subgroup(for: item, store: store)
        let isLocked = item.isLocked || group?.isLocked == true

        return VStack(alignment: .leading, spacing: 4) {
            popoverAction(icon: "checklist", title: String(localized: "多选字幕块")) {
                popoverMode = .multiSelect
                project.isSubtitleMultiSelecting = true
                if !project.selectedIDs.contains(item.id) {
                    project.selectedIDs.insert(item.id)
                }
            }

            popoverAction(icon: "pencil", title: String(localized: "编辑内容"), disabled: isLocked) {
                editingText = item.text
                isShowingBlockActions = false
                isEditingText = true
            }

            popoverAction(icon: "clock", title: String(localized: "更改显示时间"), disabled: isLocked) {
                isShowingBlockActions = false
                beginEditingTime()
            }

            popoverAction(icon: "rectangle.3.group", title: String(localized: "移动到分组"), showsChevron: true, disabled: isLocked) {
                popoverMode = .groups
            }

            popoverAction(icon: "textformat", title: String(localized: "设定样式"), showsChevron: true, disabled: isLocked) {
                popoverMode = .styles
            }

            Divider()
                .opacity(0.35)
                .padding(.vertical, 2)

            popoverAction(icon: "trash", title: String(localized: "删除字幕"), isDestructive: true, disabled: isLocked) {
                isShowingBlockActions = false
                project.deleteSubtitle(id: item.id)
            }
        }
    }

    private var groupsPage: some View {
        VStack(alignment: .leading, spacing: 4) {
            popoverBackButton(title: String(localized: "移动到分组"))

            ForEach(store.sortedGroups) { group in
                popoverAction(
                    icon: item.groupID == group.id ? "checkmark.circle.fill" : "circle.fill",
                    title: group.name,
                    iconColor: group.color
                ) {
                    isShowingBlockActions = false
                    if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                        project.assignSelectedSubtitles(toGroup: group.id)
                    } else {
                        project.assignSubtitle(id: item.id, toGroup: group.id)
                    }
                }
            }
        }
    }

    private var stylesPage: some View {
        VStack(alignment: .leading, spacing: 4) {
            popoverBackButton(title: String(localized: "设定样式"))

            popoverAction(
                icon: item.hasIndependentPresentation ? "checkmark.circle.fill" : "link",
                title: String(localized: "跟随小组样式"),
                disabled: !item.hasIndependentPresentation
            ) {
                isShowingBlockActions = false
                if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                    project.setSelectedSubtitleStyleOverride(styleID: nil)
                } else {
                    project.followGroupStyle(id: item.id)
                }
            }

            if !store.styles.isEmpty {
                Divider()
                    .opacity(0.35)
                    .padding(.vertical, 2)
            }

            ForEach(store.styles) { style in
                popoverAction(
                    icon: item.styleID == style.id ? "checkmark.circle.fill" : "circle",
                    title: style.name
                ) {
                    isShowingBlockActions = false
                    if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                        project.setSelectedSubtitleStyleOverride(styleID: style.id)
                    } else {
                        project.setSubtitleStyleOverride(id: item.id, styleID: style.id)
                    }
                }
            }
        }
    }

    private var multiSelectPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            popoverBackButton(title: String(localized: "多选字幕块"))

            HStack(spacing: 8) {
                Button {
                    project.selectedIDs = Set(currentGroupItems.map(\.id))
                    project.isSubtitleMultiSelecting = project.selectedIDs.count > 1
                } label: {
                    Text(String(localized: "全选"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }

                Button {
                    project.selectedIDs = [item.id]
                    project.isSubtitleMultiSelecting = false
                } label: {
                    Text(String(localized: "只选当前"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }

                Spacer(minLength: 0)

                Button {
                    project.isSubtitleMultiSelecting = project.selectedIDs.count > 1
                    isShowingBlockActions = false
                } label: {
                    Text(String(localized: "完成"))
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.stropheAccent.opacity(0.18), in: Capsule())
                }
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(currentGroupItems) { candidate in
                        multiSelectRow(candidate)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: min(max(CGFloat(max(currentGroupItems.count, 1)) * 42, 220), 340))
        }
    }

    private func popoverBackButton(title: String) -> some View {
        Button {
            popoverMode = .actions
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }

    private func popoverAction(
        icon: String,
        title: String,
        showsChevron: Bool = false,
        iconColor: Color? = nil,
        isDestructive: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor ?? (isDestructive ? Color.red : Color.stropheAccent))
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isDestructive ? Color.red : Color.primary)

                Spacer(minLength: 0)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(disabled ? 0.38 : 1)
        }
        .disabled(disabled)
    }

    private func multiSelectRow(_ candidate: SubtitleItem) -> some View {
        let isSelected = project.selectedIDs.contains(candidate.id)
        let title = candidate.text.isEmpty ? String(localized: "待录入字幕") : candidate.text
        let start = candidate.startTime.map(formatCompactTime) ?? "--:--"
        let end = candidate.endTime.map(formatCompactTime) ?? "--:--"

        return Button {
            toggleMultiSelection(candidate.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.stropheAccent : Color.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    Text("\(start) - \(end)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.stropheAccent.opacity(0.14) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
    }

    private func toggleMultiSelection(_ id: UUID) {
        if project.selectedIDs.contains(id) {
            if project.selectedIDs.count > 1 {
                project.selectedIDs.remove(id)
            }
        } else {
            project.selectedIDs.insert(id)
        }
        project.isSubtitleMultiSelecting = project.selectedIDs.count > 1
    }

    private func beginEditingTime() {
        editingStartText = formatEditableTime(start)
        editingEndText = formatEditableTime(end)
        isEditingTime = true
    }

    private func saveEditingTime() {
        guard let newStart = parseEditableTime(editingStartText),
              let newEnd = parseEditableTime(editingEndText) else { return }
        project.updateSubtitleTime(id: item.id, newStartTime: newStart, newEndTime: newEnd)
    }

    private func formatEditableTime(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let totalSeconds = Int(clamped)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        let cs = Int(((clamped - Double(totalSeconds)) * 100).rounded())
        return h > 0
            ? String(format: "%d:%02d:%02d.%02d", h, m, s, cs)
            : String(format: "%02d:%02d.%02d", m, s, cs)
    }

    private func formatCompactTime(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let totalSeconds = Int(clamped)
        let minutes = totalSeconds / 60
        let second = totalSeconds % 60
        let tenths = Int(((clamped - Double(totalSeconds)) * 10).rounded())
        return String(format: "%02d:%02d.%01d", minutes, second, tenths)
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
            total += value * pow(60.0, Double(index))
        }
        return max(0, total)
    }

    #if os(iOS)
    private var mobileSweepSelectionGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(subtitleBlocksCoordinateSpaceName)))
            .onChanged { value in
                switch value {
                case .first(true):
                    beginMobileSweepSelection()
                case .second(true, let dragValue):
                    beginMobileSweepSelection()
                    if let dragValue {
                        onSweepSelectionChange?(dragValue.location.x)
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                isSweepSelecting = false
                onSweepSelectionEnd?()
            }
    }

    private func beginMobileSweepSelection() {
        guard !isSweepSelecting else { return }
        guard isInActiveGroup else { return }
        isSweepSelecting = true
        onSweepSelectionStart?(item)
    }
    #endif
}

#if os(macOS)
extension InteractiveSubtitleBlock {
    @ViewBuilder
    var macContextMenu: some View {
        let group = project.subgroup(for: item, store: store)
        let isLocked = item.isLocked || group?.isLocked == true

        Button {
            project.isSubtitleMultiSelecting = true
            if !project.selectedIDs.contains(item.id) {
                project.selectedIDs.insert(item.id)
            }
            popoverMode = .multiSelect
            isShowingBlockActions = true
        } label: {
            Label(String(localized: "多选字幕块"), systemImage: "checklist")
        }

        Divider()

        Button {
            editingText = item.text
            isEditingText = true
        } label: {
            Label(String(localized: "编辑内容"), systemImage: "pencil")
        }
        .disabled(isLocked)

        Button {
            beginEditingTime()
        } label: {
            Label(String(localized: "更改显示时间"), systemImage: "clock")
        }
        .disabled(isLocked)

        Menu {
            ForEach(store.sortedGroups) { g in
                Button {
                    if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                        project.assignSelectedSubtitles(toGroup: g.id)
                    } else {
                        project.assignSubtitle(id: item.id, toGroup: g.id)
                    }
                } label: {
                    if item.groupID == g.id {
                        Label(g.name, systemImage: "checkmark.circle.fill")
                    } else {
                        Label(g.name, systemImage: "circle")
                    }
                }
            }
        } label: {
            Label(String(localized: "移动到分组"), systemImage: "rectangle.3.group")
        }
        .disabled(isLocked)

        Menu {
            Button {
                if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                    project.setSelectedSubtitleStyleOverride(styleID: nil)
                } else {
                    project.followGroupStyle(id: item.id)
                }
            } label: {
                Label(String(localized: "跟随小组样式"), systemImage: item.hasIndependentPresentation ? "link" : "checkmark.circle.fill")
            }
            .disabled(!item.hasIndependentPresentation)

            if !store.styles.isEmpty {
                Divider()
                ForEach(store.styles) { style in
                    Button {
                        if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                            project.setSelectedSubtitleStyleOverride(styleID: style.id)
                        } else {
                            project.setSubtitleStyleOverride(id: item.id, styleID: style.id)
                        }
                    } label: {
                        if item.styleID == style.id {
                            Label(style.name, systemImage: "checkmark.circle.fill")
                        } else {
                            Label(style.name, systemImage: "circle")
                        }
                    }
                }
            }
        } label: {
            Label(String(localized: "设定样式"), systemImage: "textformat")
        }
        .disabled(isLocked)

        Divider()

        Button(role: .destructive) {
            project.deleteSubtitle(id: item.id)
        } label: {
            Label(String(localized: "删除字幕"), systemImage: "trash")
        }
        .disabled(isLocked)
    }
}
#endif
