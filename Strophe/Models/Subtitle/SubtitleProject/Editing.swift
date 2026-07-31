//
//  SubtitleProject+Editing.swift
//  Strophe
//
//  Subtitle editing operations with undo/redo support
//

import Foundation
import Combine

extension SubtitleProject {
    struct SubtitleTimingState {
        var startTime: TimeInterval?
        var endTime: TimeInterval?
        var karaoke: KaraokeProgram?
    }

    typealias SubtitleTimingSnapshot = [UUID: SubtitleTimingState]

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
            snapshot[item.id] = SubtitleTimingState(
                startTime: item.startTime,
                endTime: item.endTime,
                karaoke: item.karaoke
            )
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
            updatedItems[index].karaoke = timing.karaoke
        }

        updatedItems.sort(by: stableSubtitleSort)
        items = updatedItems
        clearKaraokeTimingPreview()
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
            !isLockedForEditing(items[index])
        else { return }
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
        mutateItems { updated in
            for index in updated.indices
            where selectedIDs.contains(updated[index].id) && !isLockedForEditing(updated[index]) {
                updated[index].groupID = groupID
            }
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

    func selectAllSubtitles() {
        selectedIDs = Set(items.map(\.id))
    }

    func clearText(in groupID: UUID) {
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        mutateItems { updated in
            for index in updated.indices
            where belongsToGroup(updated[index], groupID: groupID) && !isLockedForEditing(updated[index]) {
                updated[index].replaceTextPreservingKaraoke("")
            }
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
        registerUndo(
            label: String(localized: "delete_group_subtitles"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func setSubtitleStyleOverride(id: UUID, styleID: UUID?) {
        guard let index = items.firstIndex(where: { $0.id == id }),
            !isLockedForEditing(items[index])
        else { return }
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
        mutateItems { updated in
            for index in updated.indices
            where selectedIDs.contains(updated[index].id) && !isLockedForEditing(updated[index]) {
                updated[index].styleID = styleID
            }
        }
        registerUndo(label: String(localized: "set_subtitle_style"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func followGroupStyle(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
            !isLockedForEditing(items[index])
        else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        mutateItems { updated in
            updated[index].styleID = nil
            updated[index].styleOverrides = nil
            updated[index].positionOverride = nil
        }
        registerUndo(label: String(localized: "follow_group_style"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func importScript(_ text: String) {
        let parsed = SubtitleEngine.parseAnyDocument(text)
        importSubtitleDocument(parsed.result, hasTimeline: parsed.hasTimeline)
    }

    func importSubtitle(from url: URL) throws {
        let parsed = try SubtitleEngine.importDocument(from: url)
        importSubtitleDocument(parsed, hasTimeline: true)
    }

    func importSubtitleDocument(_ result: SubtitleParseResult, hasTimeline: Bool = true) {
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        let activeGroupID = StyleAndGroupStore.shared.activeGroupID

        let importedStyleIDs: [String: UUID]
        if let source = result.document.source {
            subtitleSourceDocuments = [source]
            importedStyleIDs = importASSStylesIfNeeded(from: source)
        } else {
            subtitleSourceDocuments = []
            importedStyleIDs = [:]
        }
        lastSubtitleImportDiagnostics = result.diagnostics

        self.items = result.document.blocks.enumerated().map { index, block in
            let assFields = block.interchangeMetadata?.ass?.fields
            let importedStyleName = block.interchangeMetadata?.ass?.styleName
            let karaoke: KaraokeProgram?
            if let styledText = block.interchangeMetadata?.ass?.styledText {
                karaoke = ASSKaraokeTimingParser.program(from: styledText)
            } else {
                karaoke = nil
            }
            return SubtitleItem(
                id: block.id,
                text: block.text,
                startTime: hasTimeline ? snapToFrame(block.startTime) : nil,
                endTime: hasTimeline ? snapToFrame(block.endTime) : nil,
                originalIndex: index,
                groupID: activeGroupID,
                layer: Int(assFields?["layer"] ?? "") ?? 0,
                styleID: importedStyleName.flatMap {
                    importedStyleIDs[$0] ?? StyleAndGroupStore.shared.style(named: $0)?.id
                },
                karaoke: karaoke,
                interchangeMetadata: block.interchangeMetadata
            )
        }
        self.currentIndex = 0
        registerUndo(label: String(localized: "import_script_1"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func subtitleDocument(for format: SubtitleFormat) -> SubtitleDocument {
        let store = StyleAndGroupStore.shared
        let eligibleItems = items.filter { item in
            guard !item.isHidden,
                let start = item.startTime,
                let end = item.endTime,
                start.isFinite,
                end.isFinite,
                end > start
            else {
                return false
            }
            guard let group = store.group(id: item.groupID) else {
                return true
            }
            switch group.exportPolicy {
            case .includeInAllExports, .textOnly:
                return true
            case .burnedInOnly, .excludeByDefault, .referenceOnly:
                return false
            }
        }
        let blocks = eligibleItems.compactMap { item -> SubtitleBlock? in
            guard let start = item.startTime, let end = item.endTime else {
                return nil
            }
            return SubtitleBlock(
                id: item.id,
                startTime: start,
                endTime: end,
                text: item.text,
                interchangeMetadata: item.interchangeMetadata
            )
        }
        let referencedDocumentIDs = Set(
            blocks.compactMap { $0.interchangeMetadata?.sourceDocumentID }
        )
        let source = subtitleSourceDocuments.first {
            $0.format == format && referencedDocumentIDs.contains($0.id)
        }
        var document = SubtitleDocument(
            format: format,
            blocks: blocks,
            source: source
        )
        document.karaokeExportStates = Dictionary(
            uniqueKeysWithValues: eligibleItems.compactMap { item in
                guard item.startTime != nil, item.endTime != nil else {
                    return nil
                }
                if let program = item.activeKaraoke {
                    return (item.id, .enabled(program))
                }
                return (item.id, .disabled)
            }
        )
        return document
    }

    private func importASSStylesIfNeeded(from source: SubtitleSourceDocument) -> [String: UUID] {
        guard let ass = source.ass else { return [:] }
        return StyleAndGroupStore.shared.importASSStyles(
            ass.styles,
            playResolutionX: ass.playResolutionX,
            playResolutionY: ass.playResolutionY
        )
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

        var updated = items
        if let index = updated.firstIndex(where: { $0.startTime == nil }) {
            updated[index].startTime = snappedStart
            updated[index].endTime = snappedEnd
            updated[index].groupID = targetGroupID
        } else {
            let newBlock = SubtitleItem(
                text: String(localized: "draft_subtitle"), startTime: snappedStart, endTime: snappedEnd,
                originalIndex: updated.count, groupID: targetGroupID)
            updated.append(newBlock)
        }
        updated.sort(by: stableSubtitleSort)
        items = updated
        autoUpdateCurrentIndex()
        registerUndo(
            label: String(localized: "create_subtitle_block"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func updateSubtitleTime(id: UUID, newStartTime: TimeInterval, newEndTime: TimeInterval) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            guard !isLockedForEditing(items[index]) else { return }
            let oldItems = items
            let oldSelectedIDs = selectedIDs

            let timing = snappedSubtitleTiming(
                startTime: newStartTime,
                endTime: newEndTime
            )
            var updated = items
            let oldStart = updated[index].startTime ?? timing.start
            let oldEnd = updated[index].endTime ?? timing.end
            updated[index].retimeKaraokeForCueChange(
                oldStart: oldStart,
                oldEnd: oldEnd,
                newStart: timing.start,
                newEnd: timing.end
            )
            updated[index].startTime = timing.start
            updated[index].endTime = timing.end
            updated.sort(by: stableSubtitleSort)
            items = updated
            clearKaraokeTimingPreview()
            autoUpdateCurrentIndex()
            registerUndo(
                label: String(localized: "move_subtitle_block"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
            notifyChange()
        }
    }

    func snappedSubtitleTiming(
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval) {
        let start = snapToFrame(max(0, startTime))
        let minimumDuration =
            videoFrameRate > 0
            ? 1.0 / videoFrameRate
            : 0.1
        let end = snapToFrame(
            max(start + minimumDuration, endTime)
        )
        return (
            start,
            max(start + minimumDuration, end)
        )
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
                let end = updatedItems[index].endTime
            {
                let newStart = snapToFrame(max(0, start + delta))
                let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
                let newEnd = snapToFrame(max(newStart + minDuration, end + delta))
                oldTimings[updatedItems[index].id] = SubtitleTimingState(
                    startTime: start,
                    endTime: end,
                    karaoke: updatedItems[index].karaoke
                )
                updatedItems[index].retimeKaraokeForCueChange(
                    oldStart: start,
                    oldEnd: end,
                    newStart: newStart,
                    newEnd: newEnd
                )
                updatedItems[index].startTime = newStart
                updatedItems[index].endTime = newEnd
            }
        }

        guard !oldTimings.isEmpty else { return }
        updatedItems.sort(by: stableSubtitleSort)
        items = updatedItems
        autoUpdateCurrentIndex()
        registerTimingUndo(
            label: String(localized: "move_subtitle_block"), oldTimings: oldTimings, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    func moveBlocks(ids: Set<UUID>, by delta: TimeInterval, toGroup groupID: UUID) {
        guard !ids.isEmpty else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        var updated = items
        var didChange = false

        for index in updated.indices where ids.contains(updated[index].id) {
            guard !isLockedForEditing(updated[index]),
                let start = updated[index].startTime,
                let end = updated[index].endTime
            else { continue }
            let newStart = snapToFrame(max(0, start + delta))
            let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
            let newEnd = snapToFrame(max(newStart + minDuration, end + delta))
            updated[index].retimeKaraokeForCueChange(
                oldStart: start,
                oldEnd: end,
                newStart: newStart,
                newEnd: newEnd
            )
            updated[index].startTime = newStart
            updated[index].endTime = newEnd
            updated[index].groupID = groupID
            didChange = true
        }

        guard didChange else { return }
        updated.sort(by: stableSubtitleSort)
        items = updated
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
            items[index].replaceTextPreservingKaraoke(text)
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
        syncKaraokeEditorToPlayhead(activeGroupID: activeGroupID)

        if activeSlapSubtitleID == nil,
            currentIndexCacheGroupID == activeGroupID,
            currentTime >= currentIndexCacheLowerBound,
            currentTime < currentIndexCacheUpperBound,
            items.indices.contains(currentIndex),
            scrollTargetID == items[currentIndex].id
        {
            return
        }

        var validityLowerBound = Double.infinity
        var validityUpperBound = -Double.infinity

        // Default to the current index and scroll target to maintain selection if no new block matches
        var targetIndex: Int = currentIndex
        var targetID: UUID? =
            (currentIndex >= 0 && currentIndex < items.count) ? items[currentIndex].id : scrollTargetID

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
            let index = timelineIndex.itemIndexByID[firstMatch.id]
        {
            targetIndex = index
            targetID = firstMatch.id
            let start = firstMatch.startTime ?? currentTime
            let end = firstMatch.endTime ?? (start + 0.1)
            validityLowerBound = start
            validityUpperBound = end.nextUp
        } else if let untimedItem = timelineIndex.untimedItems.first(where: { item in
            guard let activeGroupID else { return true }
            return belongsToGroup(item, groupID: activeGroupID)
        }), let index = timelineIndex.itemIndexByID[untimedItem.id] {
            targetIndex = index
            targetID = untimedItem.id
        } else if let activeGroupID = activeGroupID {
            // Reuse the sorted index instead of allocating and scanning an entire
            // active-group array on every playback tick between subtitle blocks.
            let matchesActiveGroup: (SubtitleItem) -> Bool = {
                self.belongsToGroup($0, groupID: activeGroupID)
            }
            let nextUpcoming = timelineIndex.firstTimedItem(
                startingAfter: currentTime,
                matching: matchesActiveGroup
            )
            if let lastPlayed = timelineIndex.lastTimedItem(
                startingOnOrBefore: currentTime,
                matching: matchesActiveGroup
            ), let index = timelineIndex.itemIndexByID[lastPlayed.id] {
                targetIndex = index
                targetID = lastPlayed.id
            } else if let nextUpcoming,
                let index = timelineIndex.itemIndexByID[nextUpcoming.id]
            {
                targetIndex = index
                targetID = nextUpcoming.id
            }
            validityLowerBound = currentTime
            validityUpperBound = nextUpcoming?.startTime ?? .infinity
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
        currentIndexCacheGroupID = activeGroupID
        currentIndexCacheLowerBound = validityLowerBound
        currentIndexCacheUpperBound = validityUpperBound
    }

    /// Keeps the Karaoke inspector attached to playback rather than to a stale
    /// click selection. This runs before the current-index fast path so crossing
    /// a cue boundary, seeking, frame stepping and timeline scrubbing all share
    /// the same behaviour.
    private func syncKaraokeEditorToPlayhead(activeGroupID: UUID?) {
        guard activeSlapSubtitleID == nil else { return }

        if isKaraokeEditorManuallyClosed {
            if karaokeEditingItemID != nil {
                karaokeEditingItemID = nil
            }
            return
        }

        // Playback ticks arrive at the video's frame rate. Once the ordinary
        // cue containing the playhead has already established the current-index
        // cache, there is no Karaoke state to synchronize until that cue ends.
        // Avoid doing timeline queries on every tick in that common case.
        if karaokeEditingItemID == nil,
            karaokeEditorDismissedItemID == nil,
            currentIndexCacheGroupID == activeGroupID,
            currentTime >= currentIndexCacheLowerBound,
            currentTime < currentIndexCacheUpperBound
        {
            return
        }

        if let editingID = karaokeEditingItemID,
            let editingItem = timelineIndex.item(id: editingID),
            editingItem.activeKaraoke != nil,
            let start = editingItem.startTime,
            let end = editingItem.endTime,
            currentTime >= start,
            currentTime < end,
            (activeGroupID.map({ belongsToGroup(editingItem, groupID: $0) }) ?? true)
        {
            let desiredSelection: Set<UUID> = [editingID]
            if selectedIDs != desiredSelection {
                selectedIDs = desiredSelection
                isSubtitleMultiSelecting = false
            }
            return
        }

        let visibleItems = timelineIndex.visibleItems(in: currentTime...currentTime)
        let activeItem =
            visibleItems
            .filter { item in
                guard item.activeKaraoke != nil,
                    let start = item.startTime,
                    let end = item.endTime,
                    currentTime >= start,
                    currentTime < end
                else {
                    return false
                }
                if let activeGroupID {
                    return belongsToGroup(item, groupID: activeGroupID)
                }
                return true
            }
            .sorted(by: stableSubtitleSort)
            .first

        if let activeItem {
            if karaokeEditorDismissedItemID == activeItem.id {
                return
            }
            if karaokeEditorDismissedItemID != nil {
                karaokeEditorDismissedItemID = nil
            }
            let desiredSelection: Set<UUID> = [activeItem.id]
            if selectedIDs != desiredSelection {
                selectedIDs = desiredSelection
                isSubtitleMultiSelecting = false
            } else if karaokeEditingItemID != activeItem.id {
                karaokeEditingItemID = activeItem.id
            }
        } else {
            let hasVisibleSubtitle = visibleItems.contains { item in
                guard let start = item.startTime,
                    let end = item.endTime,
                    currentTime >= start,
                    currentTime < end
                else {
                    return false
                }
                if let activeGroupID {
                    return belongsToGroup(item, groupID: activeGroupID)
                }
                return true
            }

            if hasVisibleSubtitle {
                // @Published emits even when assigning nil to nil. These guards
                // are important: without them every playback tick invalidates
                // the entire editor view hierarchy for an ordinary subtitle.
                if karaokeEditingItemID != nil {
                    karaokeEditingItemID = nil
                }
                if karaokeEditorDismissedItemID != nil {
                    karaokeEditorDismissedItemID = nil
                }
            } else if let editingID = karaokeEditingItemID {
                // Empty timeline gaps retain the last Karaoke inspector. Only
                // discard it if its source cue no longer exists or was disabled.
                let retainedItem = timelineIndex.item(id: editingID)
                if retainedItem?.activeKaraoke == nil {
                    karaokeEditingItemID = nil
                }
            }
        }
    }
}
