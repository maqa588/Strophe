//
//  SubtitleProject+Editing.swift
//  Strophe
//
//  Subtitle editing operations with undo/redo support
//

import Foundation
import Combine

extension SubtitleProject {
    typealias SubtitleTimingSnapshot = [UUID: (startTime: TimeInterval?, endTime: TimeInterval?)]

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    func registerUndo(label: String, oldItems: [SubtitleItem], oldSelectedIDs: Set<UUID>) {
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

    func registerTimingUndo(label: String, oldTimings: SubtitleTimingSnapshot, oldSelectedIDs: Set<UUID>) {
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

    func timingSnapshot(for ids: Set<UUID>) -> SubtitleTimingSnapshot {
        var snapshot: SubtitleTimingSnapshot = [:]
        snapshot.reserveCapacity(ids.count)
        for item in items where ids.contains(item.id) {
            snapshot[item.id] = (item.startTime, item.endTime)
        }
        return snapshot
    }

    func applyTimingSnapshot(_ snapshot: SubtitleTimingSnapshot, selectedIDs: Set<UUID>) {
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

    func stableSubtitleSort(_ a: SubtitleItem, _ b: SubtitleItem) -> Bool {
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
        // Legacy subtitle files can have a nil groupID. Their fallback must be
        // stable: resolving them through activeGroup made every group switch look
        // like the cues had physically moved to the newly active group.
        store.group(id: item.groupID) ?? store.groups.first
    }

    func belongsToGroup(_ item: SubtitleItem, groupID: UUID, store: StyleAndGroupStore = .shared) -> Bool {
        subgroup(for: item, store: store)?.id == groupID
    }

    func cueCount(in groupID: UUID) -> Int {
        items.filter { belongsToGroup($0, groupID: groupID) }.count
    }

    func selectedCueCount(in groupID: UUID) -> Int {
        items.filter { selectedIDs.contains($0.id) && belongsToGroup($0, groupID: groupID) }.count
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
        registerUndo(label: String(localized: "move_to_group"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func assignSelectedSubtitles(toGroup groupID: UUID) {
        guard !selectedIDs.isEmpty else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        for index in items.indices where selectedIDs.contains(items[index].id) && !isLockedForEditing(items[index]) {
            items[index].groupID = groupID
        }
        registerUndo(label: String(localized: "move_to_group"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func assignSelectedSubtitlesToShortcutGroup(_ number: Int, store: StyleAndGroupStore = .shared) -> Bool {
        guard let group = store.shortcutGroup(number: number) else { return false }
        assignSelectedSubtitles(toGroup: group.id)
        return true
    }

    func selectAllCues(in groupID: UUID) {
        selectedIDs = Set(items.filter { belongsToGroup($0, groupID: groupID) }.map(\.id))
    }

    func clearText(in groupID: UUID) {
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        for index in items.indices where belongsToGroup(items[index], groupID: groupID) && !isLockedForEditing(items[index]) {
            items[index].text = ""
        }
        registerUndo(label: String(localized: "clear_group_text"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func deleteCues(in groupID: UUID) {
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        items.removeAll { item in
            belongsToGroup(item, groupID: groupID) && !isLockedForEditing(item)
        }
        selectedIDs.subtract(oldItems.filter { belongsToGroup($0, groupID: groupID) }.map(\.id))
        registerUndo(label: String(localized: "delete_group_subtitles"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func setSubtitleStyleOverride(id: UUID, styleID: UUID?) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !isLockedForEditing(items[index]) else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        items[index].styleID = styleID
        registerUndo(label: String(localized: "set_subtitle_style"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func setSelectedSubtitleStyleOverride(styleID: UUID?) {
        guard !selectedIDs.isEmpty else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        for index in items.indices where selectedIDs.contains(items[index].id) && !isLockedForEditing(items[index]) {
            items[index].styleID = styleID
        }
        registerUndo(label: String(localized: "set_subtitle_style"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
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
        registerUndo(label: String(localized: "follow_group_style"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
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
        registerUndo(label: String(localized: "import_script_1"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
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
        registerUndo(label: String(localized: "mark_time"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    func stepBack() {
        if currentIndex > 0 {
            currentIndex -= 1
        }
    }
    
    func createSubtitleBlock(
        startTime: TimeInterval,
        endTime: TimeInterval,
        groupID requestedGroupID: UUID? = nil
    ) {
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        let store = StyleAndGroupStore.shared
        let targetGroupID = requestedGroupID ?? store.activeGroupID
        guard store.group(id: targetGroupID)?.isLocked != true else { return }
        
        let snappedStart = snapToFrame(startTime)
        let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
        let snappedEnd = snapToFrame(max(startTime + minDuration, endTime))
        
        if let index = items.firstIndex(where: { $0.startTime == nil }) {
            items[index].startTime = snappedStart
            items[index].endTime = snappedEnd
            items[index].groupID = targetGroupID
        } else {
            let newBlock = SubtitleItem(text: String(localized: "draft_subtitle"), startTime: snappedStart, endTime: snappedEnd, originalIndex: items.count, groupID: targetGroupID)
            items.append(newBlock)
        }
        
        sortItemsStable()
        registerUndo(label: String(localized: "create_subtitle_block"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
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
            registerUndo(label: String(localized: "move_subtitle_block"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
            notifyChange()
        }
    }

    func moveSelectedBlocks(by delta: TimeInterval) {
        moveBlocks(ids: selectedIDs, by: delta)
    }

    func moveBlocks(ids: Set<UUID>, by delta: TimeInterval) {
        guard !ids.isEmpty else { return }
        let oldSelectedIDs = selectedIDs

        var updatedItems = items
        var oldTimings: SubtitleTimingSnapshot = [:]
        oldTimings.reserveCapacity(ids.count)

        for index in updatedItems.indices where ids.contains(updatedItems[index].id) {
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
        registerTimingUndo(label: String(localized: "move_subtitle_block"), oldTimings: oldTimings, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func moveBlocks(ids: Set<UUID>, by delta: TimeInterval, toGroup groupID: UUID) {
        guard !ids.isEmpty else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        var didChange = false

        for index in items.indices where ids.contains(items[index].id) {
            guard !isLockedForEditing(items[index]),
                  let start = items[index].startTime,
                  let end = items[index].endTime else { continue }
            let newStart = snapToFrame(max(0, start + delta))
            let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
            let newEnd = snapToFrame(max(newStart + minDuration, end + delta))
            items[index].startTime = newStart
            items[index].endTime = newEnd
            items[index].groupID = groupID
            didChange = true
        }

        guard didChange else { return }
        sortItemsStable()
        autoUpdateCurrentIndex()
        registerUndo(
            label: String(localized: "move_subtitle_block_to_group"),
            oldItems: oldItems,
            oldSelectedIDs: oldSelectedIDs
        )
        notifyChange()
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
            registerUndo(label: String(localized: "edit_text"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        }
        notifyChange()
    }
    
    func deleteSubtitle(id: UUID) {
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        items.removeAll(where: { $0.id == id && !isLockedForEditing($0) })
        registerUndo(label: String(localized: "delete_subtitle"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }
    
    func deleteSubtitles(ids: Set<UUID>) {
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        items.removeAll(where: { ids.contains($0.id) && !isLockedForEditing($0) })
        registerUndo(label: String(localized: "delete_subtitle"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func autoUpdateCurrentIndex() {
        let activeGroupID = StyleAndGroupStore.shared.activeGroupID
        
        // Default to the current index and scroll target to maintain selection if no new block matches
        var targetIndex: Int = currentIndex
        var targetID: UUID? = (currentIndex >= 0 && currentIndex < items.count) ? items[currentIndex].id : scrollTargetID
        
        // Ensure the fallback targetID belongs to the active group if possible
        if let tid = targetID, let item = items.first(where: { $0.id == tid }), let activeGroupID = activeGroupID {
            if !belongsToGroup(item, groupID: activeGroupID) {
                targetID = nil
            }
        }
        
        if let activeID = activeSlapSubtitleID {
            if let index = items.firstIndex(where: { $0.id == activeID }) {
                targetIndex = index
                targetID = activeID
            }
        } else if let firstMatch = timelineIndex.visibleItems(in: currentTime...currentTime)
            .first(where: { item in
                if let activeGroupID = activeGroupID {
                    return belongsToGroup(item, groupID: activeGroupID)
                }
                return true
            }),
                  let index = timelineIndex.itemIndexByID[firstMatch.id] {
            targetIndex = index
            targetID = firstMatch.id
        } else if let untimedItem = timelineIndex.untimedItems.first(where: { item in
            activeGroupID == nil || belongsToGroup(item, groupID: activeGroupID!)
        }), let index = timelineIndex.itemIndexByID[untimedItem.id] {
            targetIndex = index
            targetID = untimedItem.id
        } else if let activeGroupID = activeGroupID {
            // Reuse the sorted index instead of allocating and scanning an entire
            // active-group array on every playback tick between subtitle blocks.
            if let lastPlayed = timelineIndex.lastTimedItem(
                startingOnOrBefore: currentTime,
                matching: { belongsToGroup($0, groupID: activeGroupID) }
            ), let index = timelineIndex.itemIndexByID[lastPlayed.id] {
                targetIndex = index
                targetID = lastPlayed.id
            } else if let firstUpcoming = timelineIndex.firstTimedItem(
                matching: { belongsToGroup($0, groupID: activeGroupID) }
            ), let index = timelineIndex.itemIndexByID[firstUpcoming.id] {
                targetIndex = index
                targetID = firstUpcoming.id
            }
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
