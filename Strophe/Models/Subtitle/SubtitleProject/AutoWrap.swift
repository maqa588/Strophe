//
//  SubtitleProject+AutoWrap.swift
//  Strophe
//
//  Auto-wrap operations for subtitle blocks
//

import Foundation
import Combine

extension SubtitleProject {
    func autoWrapSelectedSubtitles(
        maximumLength: Int,
        languageMode: AutoWrapLanguageMode,
        outputMode: AutoWrapOutputMode
    ) {
        let selected = items.filter { selectedIDs.contains($0.id) && !isLockedForEditing($0) }
        guard !selected.isEmpty else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs

        switch outputMode {
        case .insertLineBreaks:
            var updated = items
            for index in updated.indices where selectedIDs.contains(updated[index].id) && !isLockedForEditing(updated[index]) {
                let lines = LanguageProcessingService.wrappedLines(
                    updated[index].text,
                    maximumLength: maximumLength,
                    mode: languageMode
                )
                updated[index].text = lines.joined(separator: "\n")
            }
            items = updated
        case .splitSubtitleBlocks:
            let selectedIDSet = Set(selected.map(\.id))
            var replacements: [UUID: [SubtitleItem]] = [:]
            var newSelection: Set<UUID> = []
            var nextOriginalIndex = (items.map(\.originalIndex).max() ?? 0) + 1
            for item in selected {
                let lines = LanguageProcessingService.wrappedLines(
                    item.text,
                    maximumLength: maximumLength,
                    mode: languageMode
                )
                guard lines.count > 1 else { continue }
                let totalWeight = max(1, lines.reduce(0) { $0 + max(1, $1.count) })
                var consumedWeight = 0
                var splitItems: [SubtitleItem] = []
                for (lineIndex, line) in lines.enumerated() {
                    var split = item
                    if lineIndex > 0 {
                        split.id = UUID()
                        split.originalIndex = nextOriginalIndex
                        nextOriginalIndex += 1
                    }
                    split.text = line
                    if let start = item.startTime, let end = item.endTime, end > start {
                        let duration = end - start
                        let lineWeight = max(1, line.count)
                        split.startTime = start + duration * Double(consumedWeight) / Double(totalWeight)
                        consumedWeight += lineWeight
                        split.endTime = lineIndex == lines.count - 1
                            ? end
                            : start + duration * Double(consumedWeight) / Double(totalWeight)
                    }
                    splitItems.append(split)
                    newSelection.insert(split.id)
                }
                replacements[item.id] = splitItems
            }
            if !replacements.isEmpty {
                var rebuilt: [SubtitleItem] = []
                rebuilt.reserveCapacity(items.count + replacements.values.reduce(0) { $0 + $1.count - 1 })
                for item in items {
                    if let split = replacements[item.id] {
                        rebuilt.append(contentsOf: split)
                    } else {
                        rebuilt.append(item)
                        if selectedIDSet.contains(item.id) { newSelection.insert(item.id) }
                    }
                }
                items = rebuilt
                selectedIDs = newSelection
            }
        }

        guard items != oldItems else { return }
        registerUndo(label: String(localized: "auto_line_wrap"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        sortItemsStable()
        notifyChange()
    }
}
