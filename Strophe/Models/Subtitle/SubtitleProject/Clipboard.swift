//
//  SubtitleProject+Clipboard.swift
//  Strophe
//
//  Clipboard operations for subtitle blocks
//

import Foundation
import Combine

extension SubtitleProject {
    var canCopySelectedSubtitleBlocks: Bool { !selectedIDs.isEmpty }
    var canCutSelectedSubtitleBlocks: Bool {
        items.contains { selectedIDs.contains($0.id) && !isLockedForEditing($0) }
    }
    var canPasteSubtitleBlocks: Bool {
        !subtitleClipboard.isEmpty && StyleAndGroupStore.shared.activeGroup?.isLocked != true
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
        registerUndo(label: String(localized: "cut_subtitle_block"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
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
        registerUndo(label: String(localized: "paste_subtitle_block"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
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
}
