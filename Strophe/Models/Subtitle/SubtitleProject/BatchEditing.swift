//
//  SubtitleProject+BatchEditing.swift
//  Strophe
//

import Foundation

extension SubtitleProject {
    func filteredSubtitleItems(
        query: String,
        options: SubtitleSearchOptions,
        filter: SubtitleFilter,
        groupID: UUID? = nil
    ) -> [SubtitleItem] {
        items.filter { item in
            if let groupID, !belongsToGroup(item, groupID: groupID) {
                return false
            }
            let passesFilter: Bool
            switch filter {
            case .all:
                passesFilter = true
            case .timed:
                passesFilter = item.startTime != nil && item.endTime != nil
            case .untimed:
                passesFilter = item.startTime == nil || item.endTime == nil
            case .overlapping:
                passesFilter = timelineIndex.overlappingItemIDs.contains(item.id)
            case .hidden:
                passesFilter = item.isHidden
            case .selected:
                passesFilter = selectedIDs.contains(item.id)
            }
            return passesFilter
                && SubtitleEditingTools.matches(item.text, query: query, options: options)
        }
    }

    @discardableResult
    func replaceSubtitleText(
        query: String,
        replacement: String,
        options: SubtitleSearchOptions,
        ids: Set<UUID>
    ) -> Int {
        guard !query.isEmpty, !ids.isEmpty else { return 0 }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        var replacementCount = 0
        mutateItems { updated in
            for index in updated.indices
            where ids.contains(updated[index].id) && !isLockedForEditing(updated[index]) {
                let replaced = SubtitleEditingTools.replacing(
                    updated[index].text,
                    query: query,
                    replacement: replacement,
                    options: options
                )
                if replaced != updated[index].text {
                    updated[index].text = replaced
                    replacementCount += 1
                }
            }
        }
        guard replacementCount > 0 else { return 0 }
        registerUndo(
            label: String(localized: "replace"),
            oldItems: oldItems,
            oldSelectedIDs: oldSelectedIDs
        )
        notifyChange()
        return replacementCount
    }

    func subtitleStatistics(for ids: Set<UUID>? = nil) -> SubtitleStatistics {
        let scopedItems: [SubtitleItem]
        if let ids {
            scopedItems = items.filter { ids.contains($0.id) }
        } else {
            scopedItems = items
        }
        return SubtitleEditingTools.statistics(for: scopedItems)
    }

    func shiftSubtitles(ids: Set<UUID>, by delta: TimeInterval) {
        let editable = items.filter {
            ids.contains($0.id) && !isLockedForEditing($0) && $0.startTime != nil
        }
        guard !editable.isEmpty else { return }
        let earliestStart = editable.compactMap(\.startTime).min() ?? 0
        let effectiveDelta = max(delta, -earliestStart)
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        mutateItems { updated in
            for index in updated.indices where ids.contains(updated[index].id) {
                guard !isLockedForEditing(updated[index]) else { continue }
                if let start = updated[index].startTime {
                    updated[index].startTime = snapToFrame(start + effectiveDelta)
                }
                if let end = updated[index].endTime {
                    updated[index].endTime = snapToFrame(end + effectiveDelta)
                }
            }
            updated.sort(by: stableSubtitleSort)
        }
        registerUndo(
            label: String(localized: "batch_shift"),
            oldItems: oldItems,
            oldSelectedIDs: oldSelectedIDs
        )
        autoUpdateCurrentIndex()
        notifyChange()
    }

    func stretchSubtitles(
        ids: Set<UUID>,
        factor: Double,
        anchor: TimeInterval? = nil
    ) {
        guard factor.isFinite, factor > 0 else { return }
        let editable = items.filter {
            ids.contains($0.id) && !isLockedForEditing($0) && $0.startTime != nil
        }
        guard !editable.isEmpty else { return }
        let resolvedAnchor = anchor ?? editable.compactMap(\.startTime).min() ?? 0
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        mutateItems { updated in
            for index in updated.indices where ids.contains(updated[index].id) {
                guard !isLockedForEditing(updated[index]) else { continue }
                if let start = updated[index].startTime {
                    updated[index].startTime = snapToFrame(
                        max(0, resolvedAnchor + (start - resolvedAnchor) * factor)
                    )
                }
                if let end = updated[index].endTime {
                    updated[index].endTime = snapToFrame(
                        max(0, resolvedAnchor + (end - resolvedAnchor) * factor)
                    )
                }
            }
            updated.sort(by: stableSubtitleSort)
        }
        registerUndo(
            label: String(localized: "batch_stretch"),
            oldItems: oldItems,
            oldSelectedIDs: oldSelectedIDs
        )
        autoUpdateCurrentIndex()
        notifyChange()
    }

    func normalizeSubtitleGaps(ids: Set<UUID>, gap: TimeInterval) {
        let ordered = items
            .filter {
                ids.contains($0.id)
                    && !isLockedForEditing($0)
                    && $0.startTime != nil
                    && $0.endTime != nil
            }
            .sorted(by: stableSubtitleSort)
        guard ordered.count > 1 else { return }

        let oldItems = items
        let oldSelectedIDs = selectedIDs
        var previousEnd = ordered[0].endTime ?? 0
        var timings: [UUID: (Double, Double)] = [:]
        for item in ordered.dropFirst() {
            guard let start = item.startTime, let end = item.endTime else { continue }
            let duration = max(frameDuration, end - start)
            let newStart = snapToFrame(max(0, previousEnd + gap))
            let newEnd = snapToFrame(newStart + duration)
            timings[item.id] = (newStart, newEnd)
            previousEnd = newEnd
        }
        applyBatchTimings(timings)
        registerUndo(
            label: String(localized: "normalize_gaps"),
            oldItems: oldItems,
            oldSelectedIDs: oldSelectedIDs
        )
        notifyChange()
    }

    func repairSubtitleOverlaps(
        ids: Set<UUID>,
        minimumGap: TimeInterval,
        mode: SubtitleOverlapRepairMode
    ) {
        let ordered = items
            .filter {
                ids.contains($0.id)
                    && !isLockedForEditing($0)
                    && $0.startTime != nil
                    && $0.endTime != nil
            }
            .sorted(by: stableSubtitleSort)
        guard ordered.count > 1 else { return }

        let oldItems = items
        let oldSelectedIDs = selectedIDs
        var timings = Dictionary(
            uniqueKeysWithValues: ordered.compactMap { item -> (UUID, (Double, Double))? in
                guard let start = item.startTime, let end = item.endTime else { return nil }
                return (item.id, (start, end))
            }
        )

        for index in 1..<ordered.count {
            let earlier = ordered[index - 1]
            let later = ordered[index]
            guard var earlierTiming = timings[earlier.id],
                  var laterTiming = timings[later.id],
                  laterTiming.0 < earlierTiming.1 + minimumGap else {
                continue
            }
            switch mode {
            case .trimEarlier:
                earlierTiming.1 = max(
                    earlierTiming.0 + frameDuration,
                    laterTiming.0 - minimumGap
                )
                timings[earlier.id] = earlierTiming
            case .shiftLater:
                let duration = max(frameDuration, laterTiming.1 - laterTiming.0)
                laterTiming.0 = earlierTiming.1 + minimumGap
                laterTiming.1 = laterTiming.0 + duration
                timings[later.id] = laterTiming
            }
        }
        applyBatchTimings(timings)
        registerUndo(
            label: String(localized: "repair_overlaps"),
            oldItems: oldItems,
            oldSelectedIDs: oldSelectedIDs
        )
        notifyChange()
    }

    private var frameDuration: Double {
        videoFrameRate > 0 ? 1 / videoFrameRate : 0.04
    }

    private func applyBatchTimings(_ timings: [UUID: (Double, Double)]) {
        mutateItems { updated in
            for index in updated.indices {
                guard let timing = timings[updated[index].id] else { continue }
                updated[index].startTime = snapToFrame(max(0, timing.0))
                updated[index].endTime = snapToFrame(max(timing.0 + frameDuration, timing.1))
            }
            updated.sort(by: stableSubtitleSort)
        }
        autoUpdateCurrentIndex()
    }
}
