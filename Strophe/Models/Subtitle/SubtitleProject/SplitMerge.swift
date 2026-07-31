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

    /// Validates that exactly one cue contains the playhead.
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

    /// Splits one cue at a time and character boundary.
    func splitSubtitle(id: UUID, at splitTime: TimeInterval, leftText: String, rightText: String) {
        guard let index = items.firstIndex(where: { $0.id == id }),
            let startTime = items[index].startTime,
            let endTime = items[index].endTime,
            !isLockedForEditing(items[index]),
            splitTime > startTime && splitTime < endTime
        else { return }

        let snappedSplit = snapToFrame(splitTime)
        guard snappedSplit > startTime, snappedSplit < endTime else { return }

        let oldItems = items
        let oldSelectedIDs = selectedIDs
        var updated = items
        let splitKaraoke = updated[index].karaoke?.split(
            atCharacterOffset: Array(leftText).count,
            timeOffset: snappedSplit - startTime,
            cueDuration: endTime - startTime,
            leftText: leftText,
            rightText: rightText
        )

        updated[index].text = leftText
        updated[index].endTime = snappedSplit
        updated[index].karaoke = splitKaraoke?.left

        let rightItem = SubtitleItem(
            id: UUID(),
            text: rightText,
            startTime: snappedSplit,
            endTime: endTime,
            originalIndex: updated[index].originalIndex,
            groupID: updated[index].groupID,
            trackIndex: updated[index].trackIndex,
            layer: updated[index].layer,
            styleID: updated[index].styleID,
            styleOverrides: updated[index].styleOverrides,
            positionOverride: updated[index].positionOverride,
            parentItemID: updated[index].parentItemID,
            languageCode: updated[index].languageCode,
            bilingualPairID: updated[index].bilingualPairID,
            isHidden: updated[index].isHidden,
            isLocked: updated[index].isLocked,
            karaoke: splitKaraoke?.right,
            interchangeMetadata: updated[index].interchangeMetadata
        )
        let leftID = updated[index].id
        updated.insert(rightItem, at: index + 1)
        updated.sort(by: stableSubtitleSort)
        items = updated
        clearKaraokeTimingPreview()
        autoUpdateCurrentIndex()
        selectedIDs = [leftID, rightItem.id]
        registerUndo(label: String(localized: "split_subtitles"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    /// Merges consecutive selected cues, returning a localized validation error on failure.
    @discardableResult
    func mergeSelectedSubtitles() -> String? {
        guard selectedIDs.count >= 2 else {
            return String(localized: "please_select_at_least_two")
        }

        let selectedItems =
            items
            .filter { selectedIDs.contains($0.id) }
            .sorted { ($0.startTime ?? .infinity) < ($1.startTime ?? .infinity) }

        guard selectedItems.count == selectedIDs.count else {
            return String(localized: "the_selected_subtitle_blocks_contain_1")
        }
        guard selectedItems.allSatisfy({ !isLockedForEditing($0) }) else {
            return String(localized: "the_selected_subtitle_blocks_contain")
        }

        guard selectedItems.allSatisfy({ $0.startTime != nil && $0.endTime != nil }) else {
            return String(localized: "the_selected_subtitle_blocks_contain_1")
        }

        // Untimed items do not interrupt adjacency on the timeline.
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

        guard let mergedStartTime = selectedItems.compactMap(\.startTime).min(),
            let mergedEndTime = selectedItems.compactMap(\.endTime).max(),
            let firstID = selectedItems.first?.id
        else {
            return String(localized: "the_selected_subtitle_blocks_contain_1")
        }
        let mergedText = selectedItems.map { $0.text }
            .joined(separator: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        let mergedKaraoke = Self.mergedKaraokeProgram(
            from: selectedItems,
            mergedText: mergedText,
            mergedStartTime: mergedStartTime,
            mergedEndTime: mergedEndTime
        )

        let restIDs = Set(selectedItems.dropFirst().map { $0.id })

        var updated = items
        if let firstIndex = updated.firstIndex(where: { $0.id == firstID }) {
            updated[firstIndex].text = mergedText
            updated[firstIndex].startTime = mergedStartTime
            updated[firstIndex].endTime = mergedEndTime
            updated[firstIndex].karaoke = mergedKaraoke
        }
        updated.removeAll { restIDs.contains($0.id) }
        updated.sort(by: stableSubtitleSort)
        items = updated

        clearKaraokeTimingPreview()
        selectedIDs = [firstID]
        registerUndo(label: String(localized: "merge_subtitles"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
        return nil
    }
}
