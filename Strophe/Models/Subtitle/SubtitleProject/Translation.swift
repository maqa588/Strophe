//
//  SubtitleProject+Translation.swift
//  Strophe
//
//  Translation-related operations
//

import Foundation
import Combine

extension SubtitleProject {
    func translationItem(sourceID: UUID, targetGroupID: UUID) -> SubtitleItem? {
        items.first { $0.parentItemID == sourceID && $0.groupID == targetGroupID }
    }

    @discardableResult
    func upsertTranslation(
        sourceID: UUID,
        targetGroupID: UUID,
        text: String,
        languageCode: String?
    ) -> UUID? {
        guard items.contains(where: { $0.id == sourceID }) else { return nil }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        var updated = items
        var sourceIndexByID = Dictionary(uniqueKeysWithValues: updated.indices.map { (updated[$0].id, $0) })
        var translationIndexBySourceID = Dictionary(uniqueKeysWithValues: updated.indices.compactMap { index in
            updated[index].parentItemID.map {
                (TranslationLookupKey(sourceID: $0, groupID: updated[index].groupID), index)
            }
        })
        var nextOriginalIndex = (updated.map(\.originalIndex).max() ?? 0) + 1
        let translatedID = upsertTranslationWithoutUndo(
            items: &updated,
            sourceIndexByID: &sourceIndexByID,
            translationIndexBySourceID: &translationIndexBySourceID,
            nextOriginalIndex: &nextOriginalIndex,
            sourceID: sourceID,
            targetGroupID: targetGroupID,
            text: text,
            languageCode: languageCode
        )
        updated.sort(by: stableSubtitleSort)
        if updated != items { items = updated }
        registerUndo(label: String(localized: "translate_subtitles"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        autoUpdateCurrentIndex()
        notifyChange()
        return translatedID
    }

    func applyBatchTranslations(
        _ translations: [UUID: String],
        targetGroupID: UUID,
        languageCode: String?
    ) {
        guard !translations.isEmpty else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        var updated = items
        var sourceIndexByID = Dictionary(uniqueKeysWithValues: updated.indices.map { (updated[$0].id, $0) })
        var translationIndexBySourceID = Dictionary(uniqueKeysWithValues: updated.indices.compactMap { index in
            updated[index].parentItemID.map {
                (TranslationLookupKey(sourceID: $0, groupID: updated[index].groupID), index)
            }
        })
        var nextOriginalIndex = (updated.map(\.originalIndex).max() ?? 0) + 1
        for (sourceID, text) in translations {
            _ = upsertTranslationWithoutUndo(
                items: &updated,
                sourceIndexByID: &sourceIndexByID,
                translationIndexBySourceID: &translationIndexBySourceID,
                nextOriginalIndex: &nextOriginalIndex,
                sourceID: sourceID,
                targetGroupID: targetGroupID,
                text: text,
                languageCode: languageCode
            )
        }
        updated.sort(by: stableSubtitleSort)
        if updated != items { items = updated }
        registerUndo(label: String(localized: "batch_translate_subtitles"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        autoUpdateCurrentIndex()
        notifyChange()
    }

    func convertSelectedSubtitlesToPinyin() {
        let editableIDs = selectedIDs.filter { id in
            items.first(where: { $0.id == id }).map { !isLockedForEditing($0) } ?? false
        }
        guard !editableIDs.isEmpty else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        var updated = items
        for index in updated.indices where editableIDs.contains(updated[index].id) {
            updated[index].text = LanguageProcessingService.pinyinWithToneMarks(updated[index].text)
        }
        items = updated
        registerUndo(label: String(localized: "chinese_to_pinyin"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    private func upsertTranslationWithoutUndo(
        items: inout [SubtitleItem],
        sourceIndexByID: inout [UUID: Int],
        translationIndexBySourceID: inout [TranslationLookupKey: Int],
        nextOriginalIndex: inout Int,
        sourceID: UUID,
        targetGroupID: UUID,
        text: String,
        languageCode: String?
    ) -> UUID? {
        guard let sourceIndex = sourceIndexByID[sourceID] else { return nil }
        let lookupKey = TranslationLookupKey(sourceID: sourceID, groupID: targetGroupID)
        if let existingIndex = translationIndexBySourceID[lookupKey] {
            guard !isLockedForEditing(items[existingIndex]) else { return nil }
            items[existingIndex].text = text
            items[existingIndex].languageCode = languageCode
            return items[existingIndex].id
        }

        let pairID = items[sourceIndex].bilingualPairID ?? UUID()
        items[sourceIndex].bilingualPairID = pairID
        let source = items[sourceIndex]
        let targetTrack = StyleAndGroupStore.shared.sortedGroups.firstIndex(where: { $0.id == targetGroupID }) ?? source.trackIndex + 1
        let translated = SubtitleItem(
            text: text,
            startTime: source.startTime,
            endTime: source.endTime,
            originalIndex: nextOriginalIndex,
            groupID: targetGroupID,
            trackIndex: targetTrack,
            parentItemID: source.id,
            languageCode: languageCode,
            bilingualPairID: pairID
        )
        items.append(translated)
        nextOriginalIndex += 1
        sourceIndexByID[translated.id] = items.endIndex - 1
        translationIndexBySourceID[lookupKey] = items.endIndex - 1
        return translated.id
    }

    private struct TranslationLookupKey: Hashable {
        let sourceID: UUID
        let groupID: UUID?
    }
}
