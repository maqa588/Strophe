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
        let translatedID = upsertTranslationWithoutUndo(
            sourceID: sourceID,
            targetGroupID: targetGroupID,
            text: text,
            languageCode: languageCode
        )
        registerUndo(label: String(localized: "translate_subtitles"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        sortItemsStable()
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
        for (sourceID, text) in translations {
            _ = upsertTranslationWithoutUndo(
                sourceID: sourceID,
                targetGroupID: targetGroupID,
                text: text,
                languageCode: languageCode
            )
        }
        registerUndo(label: String(localized: "batch_translate_subtitles"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        sortItemsStable()
        notifyChange()
    }

    func convertSelectedSubtitlesToPinyin() {
        let editableIDs = selectedIDs.filter { id in
            items.first(where: { $0.id == id }).map { !isLockedForEditing($0) } ?? false
        }
        guard !editableIDs.isEmpty else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        for index in items.indices where editableIDs.contains(items[index].id) {
            items[index].text = LanguageProcessingService.pinyinWithToneMarks(items[index].text)
        }
        registerUndo(label: String(localized: "chinese_to_pinyin"), oldItems: oldItems, oldSelectedIDs: oldSelectedIDs)
        notifyChange()
    }

    private func upsertTranslationWithoutUndo(
        sourceID: UUID,
        targetGroupID: UUID,
        text: String,
        languageCode: String?
    ) -> UUID? {
        guard let sourceIndex = items.firstIndex(where: { $0.id == sourceID }) else { return nil }
        if let existingIndex = items.firstIndex(where: { $0.parentItemID == sourceID && $0.groupID == targetGroupID }) {
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
            originalIndex: (items.map(\.originalIndex).max() ?? 0) + 1,
            groupID: targetGroupID,
            trackIndex: targetTrack,
            parentItemID: source.id,
            languageCode: languageCode,
            bilingualPairID: pairID
        )
        items.append(translated)
        return translated.id
    }
}
