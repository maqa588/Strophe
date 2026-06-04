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
#if os(iOS)
import GameController
#endif

struct InteractiveSubtitleBlock: View {
    let item: SubtitleItem
    let start: TimeInterval
    let end: TimeInterval
    let pixelsPerSecond: Double
    @ObservedObject var project: SubtitleProject
    @ObservedObject private var store = StyleAndGroupStore.shared
    @Binding var activeDragItemID: UUID?
    @Binding var activeDragEdge: TimelineInteractionLayer.Edge?
    @Binding var activeDragDelta: Double
    
    @State private var isSweepSelecting = false
    @State private var dragMode: BlockDragMode = .none
    @State private var isSnapped = false
    
    // 文字编辑弹窗控制
    @State private var isEditingText = false
    @State private var editingText = ""
    @State private var isEditingTime = false
    @State private var editingStartText = ""
    @State private var editingEndText = ""
    @State private var isShowingBlockActions = false
    @State private var popoverMode: BlockActionsMode = .actions
    
    enum BlockActionsMode { case actions, groups, styles, multiSelect }
    enum BlockDragMode {
        case move(itemID: UUID, startTimes: [UUID: Double], endTimes: [UUID: Double])
        case leftEdge(itemID: UUID, initialStart: Double, initialEnd: Double)
        case rightEdge(itemID: UUID, initialStart: Double, initialEnd: Double)
        case none
    }

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

    private func timeDelta(for dragValue: DragGesture.Value) -> Double {
        Double(dragValue.location.x - dragValue.startLocation.x) / pixelsPerSecond
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
        let isCommandPressed: Bool
        if let keyboardInput = GCKeyboard.coalesced?.keyboardInput {
            isCommandPressed = keyboardInput.button(forKeyCode: .leftGUI)?.isPressed ?? false ||
                               keyboardInput.button(forKeyCode: .rightGUI)?.isPressed ?? false
        } else {
            isCommandPressed = false
        }
        
        if isCommandPressed {
            handleCommandTapSelection()
        } else if project.isSubtitleMultiSelecting && isInActiveGroup {
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
        if NSEvent.modifierFlags.contains(.command) {
            guard self.isInActiveGroup else { return }
            if self.project.selectedIDs.contains(self.item.id) {
                self.project.selectedIDs.remove(self.item.id)
            } else {
                self.project.selectedIDs.insert(self.item.id)
            }
            self.project.isSubtitleMultiSelecting = self.project.selectedIDs.count > 1
        } else {
            self.project.selectedIDs = [self.item.id]
            self.project.isSubtitleMultiSelecting = false
        }
        #endif
    }

    private func handleCommandTapSelection() {
        guard self.isInActiveGroup else { return }
        if self.project.selectedIDs.contains(self.item.id) {
            self.project.selectedIDs.remove(self.item.id)
            if self.project.selectedIDs.isEmpty {
                self.project.isSubtitleMultiSelecting = false
            }
        } else {
            self.project.selectedIDs.insert(self.item.id)
            self.project.isSubtitleMultiSelecting = self.project.selectedIDs.count > 1
        }
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

    private func latestTextForEditing() -> String {
        project.items.first(where: { $0.id == item.id })?.text ?? item.text
    }

    private func beginEditingText() {
        editingText = latestTextForEditing()
        isEditingText = true
    }
    
    private var currentStart: Double {
        if item.id == activeDragItemID {
            if activeDragEdge == .left {
                return start + activeDragDelta
            } else if activeDragEdge != .right {
                return start + activeDragDelta
            }
        } else if activeDragEdge == nil && activeDragItemID != nil && project.selectedIDs.contains(item.id) {
            return start + activeDragDelta
        }
        return start
    }
    
    private var currentEnd: Double {
        if item.id == activeDragItemID {
            if activeDragEdge == .right {
                return end + activeDragDelta
            } else if activeDragEdge != .left {
                return end + activeDragDelta
            }
        } else if activeDragEdge == nil && activeDragItemID != nil && project.selectedIDs.contains(item.id) {
            return end + activeDragDelta
        }
        return end
    }
    
    var body: some View {
        let currentStartVal = currentStart
        let currentEndVal = currentEnd
        let currentWidth = max(4, CGFloat((currentEndVal - currentStartVal) * pixelsPerSecond))
        let currentX = CGFloat(currentStartVal * pixelsPerSecond)
        
        let isSelected = project.selectedIDs.contains(item.id)
        let group = project.subgroup(for: item, store: store)
        let groupColor = group?.color ?? Color.stropheBlue
        let isLocked = item.isLocked || group?.isLocked == true
        let isDimmed = item.isHidden || group?.isOverlayEnabled == false
        let hasIndependentPresentation = item.hasIndependentPresentation
        let edgeHandleWidth = min(8, max(2, currentWidth * 0.5))
        let moveHandleWidth = max(0, currentWidth - edgeHandleWidth * 2)
        
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
            
            if project.editingMode == .selection && !isLocked {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: edgeHandleWidth, height: 30)
                        .contentShape(Rectangle())
                        .cursor()
                        .highPriorityGesture(edgeDragGesture(.left))

                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: moveHandleWidth, height: 30)
                        .contentShape(Rectangle())
                        .highPriorityGesture(moveDragGesture)

                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: edgeHandleWidth, height: 30)
                        .contentShape(Rectangle())
                        .cursor()
                        .highPriorityGesture(edgeDragGesture(.right))
                }
                .frame(width: currentWidth, height: 30)
            }
        }
        // 双击字幕块自动进入编辑界面
        .onTapGesture(count: 2) {
            beginEditingText()
        }
        // 单击选中
        .onTapGesture(count: 1) {
            handleTapSelection()
        }
        #if os(macOS)
        // Command+点击多选
        .highPriorityGesture(
            TapGesture()
                .modifiers(.command)
                .onEnded {
                    handleCommandTapSelection()
                }
        )
        #endif
        #if os(iOS)
        // iOS 长按菜单
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    showBlockActions()
                }
        )
        #endif
        .popover(isPresented: $isShowingBlockActions, arrowEdge: .bottom) {
            blockActionsPopover
        }
        .contextMenu {
            blockContextMenu
        }
        .sheet(isPresented: $isEditingText) {
            SubtitleTextEditSheet(
                title: String(localized: "编辑字幕内容"),
                text: $editingText,
                isPresented: $isEditingText
            ) {
                project.updateSubtitleText(id: item.id, text: editingText)
            }
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
        .offset(x: currentX, y: 0)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var moveDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                handleMoveDragChanged(value: value)
            }
            .onEnded { value in
                handleBlockDragEnded(value: value)
            }
    }

    private func edgeDragGesture(_ edge: TimelineInteractionLayer.Edge) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                handleEdgeDragChanged(value: value, edge: edge)
            }
            .onEnded { value in
                handleBlockDragEnded(value: value)
            }
    }

    private func beginMoveDragIfNeeded() {
        if !project.selectedIDs.contains(item.id) {
            project.selectedIDs = [item.id]
        }

        var starts = [UUID: Double]()
        var ends = [UUID: Double]()
        for selectedItem in project.items where project.selectedIDs.contains(selectedItem.id) {
            starts[selectedItem.id] = selectedItem.startTime ?? 0
            ends[selectedItem.id] = selectedItem.endTime ?? 0
        }

        dragMode = .move(itemID: item.id, startTimes: starts, endTimes: ends)
        activeDragItemID = item.id
        activeDragEdge = nil
    }

    private func beginEdgeDragIfNeeded(_ edge: TimelineInteractionLayer.Edge) {
        dragMode = edge == .left
            ? .leftEdge(itemID: item.id, initialStart: start, initialEnd: end)
            : .rightEdge(itemID: item.id, initialStart: start, initialEnd: end)
        activeDragItemID = item.id
        activeDragEdge = edge
    }

    private func handleMoveDragChanged(value: DragGesture.Value) {
        guard project.editingMode == .selection else { return }
        guard !project.isLockedForEditing(item, store: store) else { return }
        guard allowsDirectBlockDrag else { return }

        let distance = hypot(value.translation.width, value.translation.height)
        if case .none = dragMode {
            guard distance >= 3 else { return }
            beginMoveDragIfNeeded()
        }

        switch dragMode {
        case .move(let itemID, let startTimes, let endTimes):
            guard let initialStart = startTimes[itemID], let initialEnd = endTimes[itemID] else { return }
            let delta = timeDelta(for: value)
            let rawProposedStart = initialStart + delta
            let rawProposedEnd = initialEnd + delta

            let snapStart = findBestSnap(for: rawProposedStart, ignoreItemID: itemID)
            let snapEnd = findBestSnap(for: rawProposedEnd, ignoreItemID: itemID)

            if let snapStart {
                activeDragDelta = snapStart - initialStart
                triggerHapticFeedbackIfNeeded()
            } else if let snapEnd {
                activeDragDelta = snapEnd - initialEnd
                triggerHapticFeedbackIfNeeded()
            } else {
                activeDragDelta = delta
                isSnapped = false
            }

        case .none:
            break
        case .leftEdge, .rightEdge:
            break
        }
    }

    private func handleEdgeDragChanged(value: DragGesture.Value, edge: TimelineInteractionLayer.Edge) {
        guard project.editingMode == .selection else { return }
        guard !project.isLockedForEditing(item, store: store) else { return }

        let distance = hypot(value.translation.width, value.translation.height)
        if case .none = dragMode {
            guard distance >= 3 else { return }
            beginEdgeDragIfNeeded(edge)
        }

        switch dragMode {
        case .leftEdge(let itemID, let initialStart, _):
            let delta = timeDelta(for: value)
            let rawProposedStart = initialStart + delta
            if let snapTime = findBestSnap(for: rawProposedStart, ignoreItemID: itemID) {
                activeDragDelta = snapTime - initialStart
                triggerHapticFeedbackIfNeeded()
            } else {
                activeDragDelta = delta
                isSnapped = false
            }

        case .rightEdge(let itemID, _, let initialEnd):
            let delta = timeDelta(for: value)
            let rawProposedEnd = initialEnd + delta
            if let snapTime = findBestSnap(for: rawProposedEnd, ignoreItemID: itemID) {
                activeDragDelta = snapTime - initialEnd
                triggerHapticFeedbackIfNeeded()
            } else {
                activeDragDelta = delta
                isSnapped = false
            }

        case .move, .none:
            break
        }
    }

    private func handleBlockDragEnded(value: DragGesture.Value) {
        defer {
            dragMode = .none
            activeDragItemID = nil
            activeDragEdge = nil
            activeDragDelta = 0
            isSnapped = false
        }

        let distance = hypot(value.translation.width, value.translation.height)
        guard distance >= 3 else { return }

        switch dragMode {
        case .leftEdge(let itemID, let initialStart, let initialEnd):
            project.updateSubtitleTime(id: itemID, newStartTime: initialStart + activeDragDelta, newEndTime: initialEnd)
        case .rightEdge(let itemID, let initialStart, let initialEnd):
            project.updateSubtitleTime(id: itemID, newStartTime: initialStart, newEndTime: initialEnd + activeDragDelta)
        case .move:
            project.moveSelectedBlocks(by: activeDragDelta)
        case .none:
            break
        }
    }

    private func findBestSnap(for time: Double, ignoreItemID: UUID) -> Double? {
        let activeThreshold = (isSnapped ? 10.0 : 6.0) / pixelsPerSecond
        var bestSnap: Double?
        var minDistance = Double.infinity

        let playheadDistance = abs(project.currentTime - time)
        if playheadDistance <= activeThreshold {
            bestSnap = project.currentTime
            minDistance = playheadDistance
        }

        if let blockSnap = project.timelineIndex.nearestSnapPoint(to: time, ignoring: ignoreItemID) {
            let blockDistance = abs(blockSnap - time)
            if blockDistance <= activeThreshold && blockDistance < minDistance {
                bestSnap = blockSnap
            }
        }

        return bestSnap
    }

    private func triggerHapticFeedbackIfNeeded() {
        guard !isSnapped else { return }
        isSnapped = true
        triggerHapticFeedback()
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
                isShowingBlockActions = false
                DispatchQueue.main.async {
                    beginEditingText()
                }
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
}

struct SubtitleTextEditSheet: View {
    let title: String
    @Binding var text: String
    @Binding var isPresented: Bool
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.stropheText)

            SubtitleTextEditingView(text: $text)
                .frame(minHeight: 130)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.stropheBlue, lineWidth: 2)
                )

            HStack(spacing: 14) {
                Button(String(localized: "Cancel")) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "确定")) {
                    onConfirm()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
        .background(Color.stropheBackground)
    }
}

#if os(macOS)
struct SubtitleTextEditingView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.08)

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 15)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        DispatchQueue.main.async {
            scrollView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        DispatchQueue.main.async {
            if scrollView.window?.firstResponder !== textView {
                scrollView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
#else
struct SubtitleTextEditingView: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 15))
            .focused($isFocused)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .onAppear {
                isFocused = true
            }
    }
}
#endif

extension InteractiveSubtitleBlock {
    @ViewBuilder
    var blockContextMenu: some View {
        let group = project.subgroup(for: item, store: store)
        let isLocked = item.isLocked || group?.isLocked == true

        Button {
            project.isSubtitleMultiSelecting = true
            if !project.selectedIDs.contains(item.id) {
                project.selectedIDs.insert(item.id)
            }
            popoverMode = .multiSelect
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isShowingBlockActions = true
            }
        } label: {
            Label(String(localized: "多选字幕块"), systemImage: "checklist")
        }

        Divider()

        Button {
            DispatchQueue.main.async {
                beginEditingText()
            }
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
