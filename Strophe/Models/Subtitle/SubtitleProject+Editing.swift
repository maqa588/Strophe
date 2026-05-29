//
//  SubtitleProject+Editing.swift
//  Strophe
//
//  Subtitle editing operations with undo/redo support
//

import Foundation

extension SubtitleProject {
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
    
    func undo() { undoManager.undo() }
    func redo() { undoManager.redo() }
    
    func importScript(_ text: String) {
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        
        let (hasTimeline, blocks) = SubtitleEngine.parseAnyText(text)

        self.items = blocks.enumerated().map { index, block in
            SubtitleItem(
                id: block.id,
                text: block.text,
                startTime: hasTimeline ? snapToFrame(block.startTime) : nil,
                endTime: hasTimeline ? snapToFrame(block.endTime) : nil,
                originalIndex: index
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
        
        let snappedStart = snapToFrame(startTime)
        let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
        let snappedEnd = snapToFrame(max(startTime + minDuration, endTime))
        
        if let index = items.firstIndex(where: { $0.startTime == nil }) {
            items[index].startTime = snappedStart
            items[index].endTime = snappedEnd
        } else {
            let newBlock = SubtitleItem(text: String(localized: "待录入字幕"), startTime: snappedStart, endTime: snappedEnd, originalIndex: items.count)
            items.append(newBlock)
        }
        
        sortItemsStable()
        registerUndo(label: String(localized: "创建字幕块"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    func updateSubtitleTime(id: UUID, newStartTime: TimeInterval, newEndTime: TimeInterval) {
        if let index = items.firstIndex(where: { $0.id == id }) {
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
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        
        for id in selectedIDs {
            if let index = items.firstIndex(where: { $0.id == id }),
               let start = items[index].startTime,
               let end = items[index].endTime {
                let newStart = snapToFrame(max(0, start + delta))
                let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
                let newEnd = snapToFrame(max(newStart + minDuration, end + delta))
                items[index].startTime = newStart
                items[index].endTime = newEnd
            }
        }
        sortItemsStable()
        registerUndo(label: String(localized: "移动字幕块"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    func handleSlapKeyDown(key: String) {
        if activeSlapKey == key { return }
        
        if let currentActiveKey = activeSlapKey, currentActiveKey != key {
            finalizeActiveSlapBlock()
        }
        
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        
        let startTime = snapToFrame(currentTime)
        let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
        let endTime = startTime + minDuration
        
        if let index = items.firstIndex(where: { $0.startTime == nil }) {
            items[index].startTime = startTime
            items[index].endTime = endTime
            activeSlapSubtitleID = items[index].id
        } else {
            let newID = UUID()
            let newBlock = SubtitleItem(id: newID, text: String(localized: "待录入字幕"), startTime: startTime, endTime: endTime, originalIndex: items.count)
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
            finalizeActiveSlapBlock()
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
    
    func sortItemsStable() {
        items.sort { a, b in
            switch (a.startTime, b.startTime) {
            case let (startA?, startB?):
                return startA < startB
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return a.originalIndex < b.originalIndex
            }
        }
        autoUpdateCurrentIndex()
    }
    
    func updateSubtitleText(id: UUID, text: String) {
        if let index = items.firstIndex(where: { $0.id == id }) {
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
        items.removeAll(where: { $0.id == id })
        registerUndo(label: String(localized: "删除字幕"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    func deleteSubtitles(ids: Set<UUID>) {
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        items.removeAll(where: { ids.contains($0.id) })
        registerUndo(label: String(localized: "删除字幕"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
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
              splitTime > startTime && splitTime < endTime else { return }
        
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        
        let snappedSplit = snapToFrame(splitTime)
        
        // 修改原 item 为左半部分
        items[index].text = leftText
        items[index].endTime = snappedSplit
        
        // 创建右半部分
        let rightItem = SubtitleItem(
            text: rightText,
            startTime: snappedSplit,
            endTime: endTime,
            originalIndex: items[index].originalIndex
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
        } else if let index = items.firstIndex(where: {
            if let start = $0.startTime, let end = $0.endTime {
                return currentTime >= start && currentTime <= end
            }
            return false
        }) {
            targetIndex = index
            targetID = items[index].id
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
