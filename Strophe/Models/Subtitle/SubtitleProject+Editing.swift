//
//  SubtitleProject+Editing.swift
//  Strophe
//
//  Subtitle editing operations with undo/redo support
//

import Foundation
import Combine

extension SubtitleProject {
    private typealias SubtitleTimingSnapshot = [UUID: (startTime: TimeInterval?, endTime: TimeInterval?)]

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }
    var canCopySelectedSubtitleBlocks: Bool { !selectedIDs.isEmpty }
    var canCutSelectedSubtitleBlocks: Bool {
        items.contains { selectedIDs.contains($0.id) && !isLockedForEditing($0) }
    }
    var canPasteSubtitleBlocks: Bool {
        !subtitleClipboard.isEmpty && StyleAndGroupStore.shared.activeGroup?.isLocked != true
    }

    private func registerUndo(label: String, oldItems: [SubtitleItem], oldSelectedIDs: Set<UUID>) {
        undoManager.registerUndo(withTarget: self) { project in
            let currentItems = project.items
            let currentSelectedIDs = project.selectedIDs
            project.items = oldItems
            project.selectedIDs = oldSelectedIDs
            project.sortItemsStable()
            project.notifyChange()
            project.registerUndo(label: label, oldItems: currentItems, oldSelectedIDs: currentSelectedIDs)
        }
        if !label.isEmpty {
            undoManager.setActionName(label)
        }
    }

    private func registerTimingUndo(label: String, oldTimings: SubtitleTimingSnapshot, oldSelectedIDs: Set<UUID>) {
        undoManager.registerUndo(withTarget: self) { project in
            let affectedIDs = Set(oldTimings.keys)
            let currentTimings = project.timingSnapshot(for: affectedIDs)
            let currentSelectedIDs = project.selectedIDs
            project.applyTimingSnapshot(oldTimings, selectedIDs: oldSelectedIDs)
            project.registerTimingUndo(label: label, oldTimings: currentTimings, oldSelectedIDs: currentSelectedIDs)
        }
        if !label.isEmpty {
            undoManager.setActionName(label)
        }
    }

    private func timingSnapshot(for ids: Set<UUID>) -> SubtitleTimingSnapshot {
        var snapshot: SubtitleTimingSnapshot = [:]
        snapshot.reserveCapacity(ids.count)
        for item in items where ids.contains(item.id) {
            snapshot[item.id] = (item.startTime, item.endTime)
        }
        return snapshot
    }

    private func applyTimingSnapshot(_ snapshot: SubtitleTimingSnapshot, selectedIDs: Set<UUID>) {
        guard !snapshot.isEmpty else { return }
        var updatedItems = items
        var indicesByID: [UUID: Int] = [:]
        indicesByID.reserveCapacity(updatedItems.count)
        for (index, item) in updatedItems.enumerated() {
            indicesByID[item.id] = index
        }

        for (id, timing) in snapshot {
            guard let index = indicesByID[id] else { continue }
            updatedItems[index].startTime = timing.startTime
            updatedItems[index].endTime = timing.endTime
        }

        updatedItems.sort(by: stableSubtitleSort)
        items = updatedItems
        self.selectedIDs = selectedIDs
        autoUpdateCurrentIndex()
        notifyChange()
    }

    private func stableSubtitleSort(_ a: SubtitleItem, _ b: SubtitleItem) -> Bool {
        switch (a.startTime, b.startTime) {
        case let (startA?, startB?):
            if startA == startB { return a.originalIndex < b.originalIndex }
            return startA < startB
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return a.originalIndex < b.originalIndex
        }
    }
    
    func undo() {
        undoManager.undo()
        objectWillChange.send()
    }

    func redo() {
        undoManager.redo()
        objectWillChange.send()
    }

    func subgroup(for item: SubtitleItem, store: StyleAndGroupStore = .shared) -> SubGroupItem? {
        store.group(id: item.groupID) ?? store.activeGroup ?? store.groups.first
    }

    func cueCount(in groupID: UUID) -> Int {
        items.filter { $0.groupID == groupID }.count
    }

    func selectedCueCount(in groupID: UUID) -> Int {
        items.filter { selectedIDs.contains($0.id) && $0.groupID == groupID }.count
    }

    func isLockedForEditing(_ item: SubtitleItem, store: StyleAndGroupStore = .shared) -> Bool {
        item.isLocked || subgroup(for: item, store: store)?.isLocked == true
    }

    func assignSubtitle(id: UUID, toGroup groupID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !isLockedForEditing(items[index]) else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        items[index].groupID = groupID
        registerUndo(label: String(localized: "移动到分组"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func assignSelectedSubtitles(toGroup groupID: UUID) {
        guard !selectedIDs.isEmpty else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        for index in items.indices where selectedIDs.contains(items[index].id) && !isLockedForEditing(items[index]) {
            items[index].groupID = groupID
        }
        registerUndo(label: String(localized: "移动到分组"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func assignSelectedSubtitlesToShortcutGroup(_ number: Int, store: StyleAndGroupStore = .shared) -> Bool {
        guard let group = store.shortcutGroup(number: number) else { return false }
        assignSelectedSubtitles(toGroup: group.id)
        return true
    }

    func selectAllCues(in groupID: UUID) {
        selectedIDs = Set(items.filter { $0.groupID == groupID }.map(\.id))
    }

    func clearText(in groupID: UUID) {
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        for index in items.indices where items[index].groupID == groupID && !isLockedForEditing(items[index]) {
            items[index].text = ""
        }
        registerUndo(label: String(localized: "清空分组文字"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func deleteCues(in groupID: UUID) {
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        items.removeAll { item in
            item.groupID == groupID && !isLockedForEditing(item)
        }
        selectedIDs.subtract(oldItems.filter { $0.groupID == groupID }.map(\.id))
        registerUndo(label: String(localized: "删除分组字幕"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func setSubtitleStyleOverride(id: UUID, styleID: UUID?) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !isLockedForEditing(items[index]) else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        items[index].styleID = styleID
        registerUndo(label: String(localized: "设置字幕样式"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func setSelectedSubtitleStyleOverride(styleID: UUID?) {
        guard !selectedIDs.isEmpty else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        for index in items.indices where selectedIDs.contains(items[index].id) && !isLockedForEditing(items[index]) {
            items[index].styleID = styleID
        }
        registerUndo(label: String(localized: "设置字幕样式"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func followGroupStyle(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !isLockedForEditing(items[index]) else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        items[index].styleID = nil
        items[index].styleOverrides = nil
        items[index].positionOverride = nil
        registerUndo(label: String(localized: "跟随小组样式"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    func importScript(_ text: String) {
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        let activeGroupID = StyleAndGroupStore.shared.activeGroupID
        
        let (hasTimeline, blocks) = SubtitleEngine.parseAnyText(text)

        self.items = blocks.enumerated().map { index, block in
            SubtitleItem(
                id: block.id,
                text: block.text,
                startTime: hasTimeline ? snapToFrame(block.startTime) : nil,
                endTime: hasTimeline ? snapToFrame(block.endTime) : nil,
                originalIndex: index,
                groupID: activeGroupID
            )
        }
        self.currentIndex = 0
        registerUndo(label: String(localized: "导入脚本"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    func markCurrentTime(_ time: TimeInterval) {
        guard currentIndex < items.count else { return }
        
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        
        let snappedTime = snapToFrame(time)
        items[currentIndex].startTime = snappedTime
        
        if currentIndex > 0 && items[currentIndex - 1].endTime == nil {
            items[currentIndex - 1].endTime = snappedTime
        }
        
        if currentIndex < items.count - 1 {
            currentIndex += 1
        }
        registerUndo(label: String(localized: "标记时间"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    func stepBack() {
        if currentIndex > 0 {
            currentIndex -= 1
        }
    }
    
    func createSubtitleBlock(startTime: TimeInterval, endTime: TimeInterval) {
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        let activeGroupID = StyleAndGroupStore.shared.activeGroupID
        
        let snappedStart = snapToFrame(startTime)
        let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
        let snappedEnd = snapToFrame(max(startTime + minDuration, endTime))
        
        if let index = items.firstIndex(where: { $0.startTime == nil }) {
            items[index].startTime = snappedStart
            items[index].endTime = snappedEnd
            items[index].groupID = items[index].groupID ?? activeGroupID
        } else {
            let newBlock = SubtitleItem(text: String(localized: "待录入字幕"), startTime: snappedStart, endTime: snappedEnd, originalIndex: items.count, groupID: activeGroupID)
            items.append(newBlock)
        }
        
        sortItemsStable()
        registerUndo(label: String(localized: "创建字幕块"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    func updateSubtitleTime(id: UUID, newStartTime: TimeInterval, newEndTime: TimeInterval) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            guard !isLockedForEditing(items[index]) else { return }
            let oldItems = items
            let oldSelectedIDs = selectedIDs
            
            let snappedStart = snapToFrame(max(0, newStartTime))
            let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
            let snappedEnd = snapToFrame(max(newStartTime + minDuration, newEndTime))
            items[index].startTime = snappedStart
            items[index].endTime = snappedEnd
            sortItemsStable()
            registerUndo(label: String(localized: "移动字幕块"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
            notifyChange()
        }
    }

    func moveSelectedBlocks(by delta: TimeInterval) {
        guard !selectedIDs.isEmpty else { return }
        let oldSelectedIDs = selectedIDs

        var updatedItems = items
        var oldTimings: SubtitleTimingSnapshot = [:]
        oldTimings.reserveCapacity(selectedIDs.count)

        for index in updatedItems.indices where selectedIDs.contains(updatedItems[index].id) {
            if !isLockedForEditing(updatedItems[index]),
               let start = updatedItems[index].startTime,
               let end = updatedItems[index].endTime {
                let newStart = snapToFrame(max(0, start + delta))
                let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
                let newEnd = snapToFrame(max(newStart + minDuration, end + delta))
                oldTimings[updatedItems[index].id] = (start, end)
                updatedItems[index].startTime = newStart
                updatedItems[index].endTime = newEnd
            }
        }

        guard !oldTimings.isEmpty else { return }
        updatedItems.sort(by: stableSubtitleSort)
        items = updatedItems
        autoUpdateCurrentIndex()
        registerTimingUndo(label: String(localized: "移动字幕块"), oldTimings: oldTimings, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    func handleSlapKeyDown(key: String) {
        if activeSlapKey == key { return }
        syncPlaybackClockFromEngine()
        
        if let currentActiveKey = activeSlapKey, currentActiveKey != key {
            finalizeActiveSlapBlock()
        }
        
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        let activeGroupID = StyleAndGroupStore.shared.activeGroupID
        
        let startTime = snapToFrame(currentTime)
        let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
        let endTime = startTime + minDuration
        
        if let index = items.firstIndex(where: { $0.startTime == nil }) {
            items[index].startTime = startTime
            items[index].endTime = endTime
            items[index].groupID = items[index].groupID ?? activeGroupID
            activeSlapSubtitleID = items[index].id
        } else {
            let newID = UUID()
            let newBlock = SubtitleItem(id: newID, text: String(localized: "待录入字幕"), startTime: startTime, endTime: endTime, originalIndex: items.count, groupID: activeGroupID)
            items.append(newBlock)
            activeSlapSubtitleID = newID
        }
        
        activeSlapKey = key
        sortItemsStable()
        registerUndo(label: String(localized: "拍打创建"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    func handleSlapKeyUp(key: String) {
        if activeSlapKey == key {
            syncPlaybackClockFromEngine()
            finalizeActiveSlapBlock()
            syncPlaybackClockFromEngine()
        }
    }
    
    func finalizeActiveSlapBlock() {
        guard let id = activeSlapSubtitleID else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        
        if let index = items.firstIndex(where: { $0.id == id }) {
            let start = items[index].startTime ?? 0
            let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
            items[index].endTime = snapToFrame(max(start + minDuration, currentTime))
        }
        activeSlapKey = nil
        activeSlapSubtitleID = nil
        
        sortItemsStable()
        registerUndo(label: String(localized: "拍打结算"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    func updateActiveSlapBlock(currentTime: TimeInterval) {
        guard let id = activeSlapSubtitleID else { return }
        if let index = items.firstIndex(where: { $0.id == id }) {
            let start = items[index].startTime ?? 0
            let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
            items[index].endTime = snapToFrame(max(start + minDuration, currentTime))
        }
    }

    var shouldDeferActiveSlapBlockTimingUpdates: Bool {
        activeSlapSubtitleID != nil
    }
    
    func sortItemsStable() {
        items.sort(by: stableSubtitleSort)
        autoUpdateCurrentIndex()
    }
    
    func updateSubtitleText(id: UUID, text: String) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            guard !isLockedForEditing(items[index]) else { return }
            let oldItems = items
            let oldSelectedIDs = selectedIDs
            items[index].text = text
            registerUndo(label: String(localized: "编辑文本"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        }
        notifyChange()
    }
    
    func deleteSubtitle(id: UUID) {
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        items.removeAll(where: { $0.id == id && !isLockedForEditing($0) })
        registerUndo(label: String(localized: "删除字幕"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    func deleteSubtitles(ids: Set<UUID>) {
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        items.removeAll(where: { ids.contains($0.id) && !isLockedForEditing($0) })
        registerUndo(label: String(localized: "删除字幕"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func copySelectedSubtitleBlocks() {
        guard canCopySelectedSubtitleBlocks else { return }
        subtitleClipboard = selectedSubtitleBlocksForClipboard()
        objectWillChange.send()
    }

    func cutSelectedSubtitleBlocks() {
        let blocksToCut = selectedSubtitleBlocksForClipboard().filter { !isLockedForEditing($0) }
        guard !blocksToCut.isEmpty else { return }

        subtitleClipboard = blocksToCut
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        let cutIDs = Set(blocksToCut.map(\.id))
        items.removeAll { cutIDs.contains($0.id) }
        selectedIDs.subtract(cutIDs)
        registerUndo(label: String(localized: "剪切字幕块"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func pasteSubtitleBlocksIntoActiveGroup(store: StyleAndGroupStore = .shared) {
        guard !subtitleClipboard.isEmpty,
              let activeGroupID = store.activeGroupID,
              store.activeGroup?.isLocked != true else { return }

        let oldItems = items
        let oldSelectedIDs = selectedIDs
        var newIDs = Set<UUID>()
        let nextOriginalIndex = (items.map(\.originalIndex).max() ?? -1) + 1

        let pastedItems = subtitleClipboard.enumerated().map { offset, source in
            var item = source
            item.id = UUID()
            item.groupID = activeGroupID
            item.originalIndex = nextOriginalIndex + offset
            newIDs.insert(item.id)
            return item
        }

        items.append(contentsOf: pastedItems)
        selectedIDs = newIDs
        sortItemsStable()
        registerUndo(label: String(localized: "粘贴字幕块"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    private func selectedSubtitleBlocksForClipboard() -> [SubtitleItem] {
        items
            .filter { selectedIDs.contains($0.id) }
            .sorted { lhs, rhs in
                switch (lhs.startTime, rhs.startTime) {
                case let (left?, right?):
                    if left == right { return lhs.originalIndex < rhs.originalIndex }
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.originalIndex < rhs.originalIndex
                }
            }
    }
    
    // MARK: - Split / Merge Operations
    
    enum SplitValidationResult {
        case ready(SubtitleItem)
        case noBlock
        case overlapping
    }
    
    /// 校验当前播放游标位置是否可以执行切分操作
    func validateSplitAtPlayhead() -> SplitValidationResult {
        let overlapping = items.filter { item in
            guard let start = item.startTime, let end = item.endTime else { return false }
            return currentTime >= start && currentTime <= end
        }
        switch overlapping.count {
        case 0:
            return .noBlock
        case 1:
            return .ready(overlapping[0])
        default:
            return .overlapping
        }
    }
    
    /// 切分字幕块：将指定字幕块在 splitTime 处拆分为两个独立字幕块
    func splitSubtitle(id: UUID, at splitTime: TimeInterval, leftText: String, rightText: String) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let startTime = items[index].startTime,
              let endTime = items[index].endTime,
              !isLockedForEditing(items[index]),
              splitTime > startTime && splitTime < endTime else { return }
        
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        
        let snappedSplit = snapToFrame(splitTime)
        
        // 修改原 item 为左半部分
        items[index].text = leftText
        items[index].endTime = snappedSplit
        
        let rightItem = SubtitleItem(
            id: UUID(),
            text: rightText,
            startTime: snappedSplit,
            endTime: endTime,
            originalIndex: items[index].originalIndex,
            groupID: items[index].groupID,
            trackIndex: items[index].trackIndex,
            styleID: items[index].styleID,
            styleOverrides: items[index].styleOverrides,
            positionOverride: items[index].positionOverride,
            parentItemID: items[index].parentItemID,
            languageCode: items[index].languageCode,
            bilingualPairID: items[index].bilingualPairID,
            isHidden: items[index].isHidden,
            isLocked: items[index].isLocked
        )
        items.insert(rightItem, at: index + 1)
        
        sortItemsStable()
        selectedIDs = [items[index].id, rightItem.id]
        registerUndo(label: String(localized: "切分字幕"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    /// 合并选中的连续字幕块，返回错误消息（nil 表示成功）
    @discardableResult
    func mergeSelectedSubtitles() -> String? {
        guard selectedIDs.count >= 2 else {
            return String(localized: "请至少选中两个字幕块才能合并")
        }
        
        // 取出被选中且已有时间的 items，按 startTime 排序
        let selectedItems = items
            .filter { selectedIDs.contains($0.id) }
            .sorted { ($0.startTime ?? .infinity) < ($1.startTime ?? .infinity) }

        guard selectedItems.allSatisfy({ !isLockedForEditing($0) }) else {
            return String(localized: "选中的字幕块中包含锁定项目，无法合并")
        }
        
        // 校验所有被选中的 item 都有时间信息
        guard selectedItems.allSatisfy({ $0.startTime != nil && $0.endTime != nil }) else {
            return String(localized: "选中的字幕块中有未设置时间的项目，无法合并")
        }
        
        // 连续性校验：检查选中项在 items 数组中的索引是否连续（中间没有未选中的 timed 字幕块）
        let timedItems = items.filter { $0.startTime != nil && $0.endTime != nil }
        let selectedIDSet = selectedIDs
        var indicesInTimed: [Int] = []
        for (i, item) in timedItems.enumerated() {
            if selectedIDSet.contains(item.id) {
                indicesInTimed.append(i)
            }
        }
        indicesInTimed.sort()
        
        if indicesInTimed.count >= 2 {
            for i in 1..<indicesInTimed.count {
                if indicesInTimed[i] - indicesInTimed[i - 1] != 1 {
                    return String(localized: "选中的字幕块不连续，请选择连续的字幕块进行合并")
                }
            }
        }
        
        let oldItems = items
        let oldSelectedIDs = self.selectedIDs
        
        // 合并数据
        let mergedStartTime = selectedItems.compactMap { $0.startTime }.min()!
        let mergedEndTime = selectedItems.compactMap { $0.endTime }.max()!
        let mergedText = selectedItems.map { $0.text }
            .joined(separator: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        
        // 保留第一个 item，删除其余
        let firstID = selectedItems[0].id
        let restIDs = Set(selectedItems.dropFirst().map { $0.id })
        
        if let firstIndex = items.firstIndex(where: { $0.id == firstID }) {
            items[firstIndex].text = mergedText
            items[firstIndex].startTime = mergedStartTime
            items[firstIndex].endTime = mergedEndTime
        }
        
        items.removeAll { restIDs.contains($0.id) }
        
        selectedIDs = [firstID]
        sortItemsStable()
        registerUndo(label: String(localized: "合并字幕"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
        return nil
    }
    
    func autoUpdateCurrentIndex() {
        // Default to the current index and scroll target to maintain selection if no new block matches
        var targetIndex: Int = currentIndex
        var targetID: UUID? = (currentIndex >= 0 && currentIndex < items.count) ? items[currentIndex].id : scrollTargetID
        
        if let activeID = activeSlapSubtitleID {
            if let index = items.firstIndex(where: { $0.id == activeID }) {
                targetIndex = index
                targetID = activeID
            }
        } else if let firstMatch = timelineIndex.visibleItems(in: currentTime...currentTime).first,
                  let index = timelineIndex.itemIndexByID[firstMatch.id] {
            targetIndex = index
            targetID = firstMatch.id
        } else if let index = items.firstIndex(where: { $0.startTime == nil }) {
            targetIndex = index
            targetID = items[index].id
        }
        
        // Ensure index is within bounds if items changed
        if !items.isEmpty {
            if targetIndex >= items.count {
                targetIndex = items.count - 1
            }
            if targetIndex < 0 {
                targetIndex = 0
            }
            // If targetID is no longer valid or nil, update it
            if targetID == nil || !items.contains(where: { $0.id == targetID }) {
                targetID = items[targetIndex].id
            }
        } else {
            targetIndex = 0
            targetID = nil
        }
        
        if currentIndex != targetIndex {
            currentIndex = targetIndex
        }
        if scrollTargetID != targetID {
            scrollTargetID = targetID
        }
    }
}
