//
//  SubtitleProject+SplitMerge.swift
//  Strophe
//
//  Split and merge operations for subtitle blocks
//

import Foundation
import Combine

extension SubtitleProject {
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
        var updated = items
        
        // 修改原 item 为左半部分
        updated[index].text = leftText
        updated[index].endTime = snappedSplit
        
        let rightItem = SubtitleItem(
            id: UUID(),
            text: rightText,
            startTime: snappedSplit,
            endTime: endTime,
            originalIndex: updated[index].originalIndex,
            groupID: updated[index].groupID,
            trackIndex: updated[index].trackIndex,
            styleID: updated[index].styleID,
            styleOverrides: updated[index].styleOverrides,
            positionOverride: updated[index].positionOverride,
            parentItemID: updated[index].parentItemID,
            languageCode: updated[index].languageCode,
            bilingualPairID: updated[index].bilingualPairID,
            isHidden: updated[index].isHidden,
            isLocked: updated[index].isLocked
        )
        let leftID = updated[index].id
        updated.insert(rightItem, at: index + 1)
        updated.sort(by: stableSubtitleSort)
        items = updated
        autoUpdateCurrentIndex()
        selectedIDs = [leftID, rightItem.id]
        registerUndo(label: String(localized: "split_subtitles"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    /// 合并选中的连续字幕块，返回错误消息（nil 表示成功）
    @discardableResult
    func mergeSelectedSubtitles() -> String? {
        guard selectedIDs.count >= 2 else {
            return String(localized: "please_select_at_least_two")
        }
        
        // 取出被选中且已有时间的 items，按 startTime 排序
        let selectedItems = items
            .filter { selectedIDs.contains($0.id) }
            .sorted { ($0.startTime ?? .infinity) < ($1.startTime ?? .infinity) }

        guard selectedItems.allSatisfy({ !isLockedForEditing($0) }) else {
            return String(localized: "the_selected_subtitle_blocks_contain")
        }
        
        // 校验所有被选中的 item 都有时间信息
        guard selectedItems.allSatisfy({ $0.startTime != nil && $0.endTime != nil }) else {
            return String(localized: "the_selected_subtitle_blocks_contain_1")
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
                    return String(localized: "the_selected_subtitle_blocks_are")
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
        registerUndo(label: String(localized: "merge_subtitles"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
        return nil
    }
}
