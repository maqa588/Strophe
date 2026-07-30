//
//  SubtitleProject+KaraokeEditing.swift
//  Strophe
//

import Foundation

extension SubtitleItem {
    var karaokeDiagnostics: [KaraokeDiagnostic] {
        guard let karaoke else { return [] }
        return KaraokeTimingDiagnostics.validate(
            program: karaoke,
            cueText: text,
            cueDuration: max(0, (endTime ?? startTime ?? 0) - (startTime ?? 0))
        )
    }

    mutating func replaceTextPreservingKaraoke(_ newText: String) {
        guard text != newText else { return }
        karaoke = karaoke?.remapped(to: newText)
        text = newText
    }

    /// Cue-edge policy:
    /// - moving both edges equally moves Karaoke with the cue;
    /// - changing the left edge preserves absolute word timing;
    /// - changing the right edge preserves existing timing while it fits;
    /// - trimming through timing clamps and repairs the complete transcript.
    mutating func retimeKaraokeForCueChange(
        oldStart: Double,
        oldEnd: Double,
        newStart: Double,
        newEnd: Double
    ) {
        guard let karaoke else { return }
        let startDelta = newStart - oldStart
        let endDelta = newEnd - oldEnd
        var updated = karaoke
        if abs(startDelta - endDelta) > 0.000_001,
           abs(startDelta) > 0.000_001 {
            updated = karaoke.shiftingOffsets(by: oldStart - newStart)
        }
        self.karaoke = updated.reconciled(
            to: text,
            cueDuration: max(0.000_001, newEnd - newStart)
        )
    }

    mutating func scaleKaraokeOffsets(by factor: Double) {
        karaoke = karaoke?.scalingOffsets(by: factor)
    }
}

@MainActor
extension SubtitleProject {
    func applyBatchKaraokePrograms(_ programs: [UUID: KaraokeProgram]) {
        guard !programs.isEmpty else { return }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        var changed = false
        for index in items.indices {
            guard let program = programs[items[index].id],
                  !isLockedForEditing(items[index]) else { continue }
            items[index].karaoke = program
            changed = true
        }
        guard changed else { return }
        registerUndo(
            label: stropheLocalizedString("karaoke_batch_recognition"),
            oldItems: oldItems,
            oldSelectedIDs: oldSelectedIDs
        )
        notifyChange()
    }

    var selectedKaraokeItem: SubtitleItem? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else {
            return nil
        }
        return items.first(where: { $0.id == id })
    }

    var karaokeEditorItem: SubtitleItem? {
        guard let id = karaokeEditingItemID,
              selectedIDs.count == 1,
              selectedIDs.contains(id),
              let item = items.first(where: { $0.id == id }),
              item.activeKaraoke != nil else {
            return nil
        }
        return item
    }

    var canToggleKaraokeEditor: Bool {
        guard let item = selectedKaraokeItem else { return false }
        return item.activeKaraoke != nil && !isLockedForEditing(item)
    }

    var isKaraokeEditorActiveForSelection: Bool {
        guard let selectedID = selectedKaraokeItem?.id else { return false }
        return karaokeEditingItemID == selectedID
    }

    /// The timeline toolbar controls only inspector visibility. Enabling or
    /// disabling Karaoke presentation belongs to each subtitle block's actions.
    func toggleKaraokeEditorForSelection() {
        guard canToggleKaraokeEditor,
              let id = selectedKaraokeItem?.id else {
            karaokeEditingItemID = nil
            isKaraokeEditorManuallyClosed = true
            return
        }
        if karaokeEditingItemID == id || !isKaraokeEditorManuallyClosed && karaokeEditingItemID != nil {
            karaokeEditingItemID = nil
            karaokeEditorDismissedItemID = id
            isKaraokeEditorManuallyClosed = true
            return
        }
        karaokeEditorDismissedItemID = nil
        isKaraokeEditorManuallyClosed = false
        karaokeEditingItemID = id
    }

    func karaokeActionItemIDs(for itemID: UUID) -> Set<UUID> {
        if selectedIDs.count > 1, selectedIDs.contains(itemID) {
            return selectedIDs
        }
        return [itemID]
    }

    func canSetKaraokeFromBlockAction(itemID: UUID) -> Bool {
        let targetIDs = karaokeActionItemIDs(for: itemID)
        return items.contains {
            targetIDs.contains($0.id)
                && $0.isTimed
                && !$0.text.isEmpty
                && !isLockedForEditing($0)
        }
    }

    func isKaraokeEnabledFromBlockAction(itemID: UUID) -> Bool {
        let targetIDs = karaokeActionItemIDs(for: itemID)
        let eligible = items.filter {
            targetIDs.contains($0.id)
                && $0.isTimed
                && !$0.text.isEmpty
                && !isLockedForEditing($0)
        }
        return !eligible.isEmpty && eligible.allSatisfy {
            $0.activeKaraoke != nil
        }
    }

    func setKaraokeFromBlockAction(
        itemID: UUID,
        isEnabled: Bool
    ) {
        let targetIDs = karaokeActionItemIDs(for: itemID)
        let eligibleIndices = items.indices.filter { index in
            let item = items[index]
            return targetIDs.contains(item.id)
                && item.isTimed
                && !item.text.isEmpty
                && !isLockedForEditing(item)
        }
        guard !eligibleIndices.isEmpty else { return }

        let oldItems = items
        let oldSelectedIDs = selectedIDs
        var updated = items
        var changedCount = 0

        for index in eligibleIndices {
            if isEnabled {
                if var retained = updated[index].karaoke {
                    guard !retained.isEnabled else { continue }
                    retained.isEnabled = true
                    updated[index].karaoke = retained
                    changedCount += 1
                } else if let start = updated[index].startTime,
                          let end = updated[index].endTime,
                          let program = KaraokeProgram.evenlyTimed(
                            text: updated[index].text,
                            duration: max(0, end - start),
                            template: .classicSweep
                          ) {
                    updated[index].karaoke = program
                    changedCount += 1
                }
            } else if updated[index].karaoke?.isEnabled == true {
                updated[index].karaoke?.isEnabled = false
                changedCount += 1
            }
        }

        guard changedCount > 0 else { return }
        items = updated
        if !isEnabled,
           let editingID = karaokeEditingItemID,
           targetIDs.contains(editingID) {
            karaokeEditingItemID = nil
            karaokeEditorDismissedItemID = nil
        }
        registerUndo(
            label: stropheLocalizedString(
                isEnabled ? "karaoke_batch_enable" : "karaoke_batch_disable"
            ),
            oldItems: oldItems,
            oldSelectedIDs: oldSelectedIDs
        )
        notifyChange()
    }

    func enableKaraoke(
        id: UUID,
        preset: KaraokeTemplatePreset = .classicSweep
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !isLockedForEditing(items[index]),
              let start = items[index].startTime,
              let end = items[index].endTime else {
            return
        }
        let program: KaraokeProgram
        if var retained = items[index].karaoke {
            guard !retained.isEnabled else { return }
            retained.isEnabled = true
            program = retained
        } else {
            guard let generated = KaraokeProgram.evenlyTimed(
                text: items[index].text,
                duration: max(0, end - start),
                template: .preset(preset)
            ) else {
                return
            }
            program = generated
        }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        items[index].karaoke = program
        registerUndo(
            label: stropheLocalizedString("karaoke_enable"),
            oldItems: oldItems,
            oldSelectedIDs: oldSelectedIDs
        )
        notifyChange()
    }

    func disableKaraoke(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !isLockedForEditing(items[index]),
              items[index].karaoke?.isEnabled == true else {
            return
        }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        items[index].karaoke?.isEnabled = false
        registerUndo(
            label: stropheLocalizedString("karaoke_disable"),
            oldItems: oldItems,
            oldSelectedIDs: oldSelectedIDs
        )
        notifyChange()
    }

    func updateKaraokeTemplate(
        id: UUID,
        configuration: KaraokeTemplateConfiguration
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !isLockedForEditing(items[index]),
              items[index].karaoke != nil,
              items[index].karaoke?.template != configuration else {
            return
        }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        items[index].karaoke?.template = configuration
        registerUndo(
            label: stropheLocalizedString("karaoke_edit_template"),
            oldItems: oldItems,
            oldSelectedIDs: oldSelectedIDs
        )
        notifyChange()
    }

    /// Applies an in-progress parameter change without creating an undo entry.
    /// The editor calls `commitKaraokeTemplatePreview` once at the end of the
    /// gesture, so a slider drag remains a single undoable action.
    func previewKaraokeTemplate(
        id: UUID,
        configuration: KaraokeTemplateConfiguration
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !isLockedForEditing(items[index]),
              items[index].karaoke != nil,
              items[index].karaoke?.template != configuration else {
            return
        }
        items[index].karaoke?.template = configuration
    }

    func commitKaraokeTemplatePreview(
        id: UUID,
        originalConfiguration: KaraokeTemplateConfiguration,
        finalConfiguration: KaraokeTemplateConfiguration
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !isLockedForEditing(items[index]),
              items[index].karaoke != nil,
              originalConfiguration != finalConfiguration else {
            return
        }

        var oldItems = items
        oldItems[index].karaoke?.template = originalConfiguration
        items[index].karaoke?.template = finalConfiguration
        registerUndo(
            label: stropheLocalizedString("karaoke_edit_template"),
            oldItems: oldItems,
            oldSelectedIDs: selectedIDs
        )
        notifyChange()
    }

    func updateKaraokeBoundary(
        itemID: UUID,
        precedingUnitID: UUID,
        to proposedOffset: Double
    ) {
        guard let itemIndex = items.firstIndex(where: { $0.id == itemID }),
              !isLockedForEditing(items[itemIndex]),
              var program = items[itemIndex].karaoke,
              let unitIndex = program.units.firstIndex(
                where: { $0.id == precedingUnitID }
              ),
              unitIndex + 1 < program.units.count else {
            return
        }

        let frameFloor = max(0.001, 1 / max(videoFrameRate, 1))
        let lower = program.units[unitIndex].startOffset + frameFloor
        let upper = program.units[unitIndex + 1].endOffset - frameFloor
        guard upper > lower else { return }
        let boundary = min(max(proposedOffset, lower), upper)
        guard abs(program.units[unitIndex].endOffset - boundary) > 0.000_001
                || abs(program.units[unitIndex + 1].startOffset - boundary) > 0.000_001 else {
            return
        }

        let oldItems = items
        let oldSelectedIDs = selectedIDs
        program.units[unitIndex].endOffset = boundary
        program.units[unitIndex + 1].startOffset = boundary
        items[itemIndex].karaoke = program
        registerUndo(
            label: stropheLocalizedString("karaoke_edit_timing"),
            oldItems: oldItems,
            oldSelectedIDs: oldSelectedIDs
        )
        notifyChange()
    }

    func updateKaraokeUnit(
        itemID: UUID,
        unitID: UUID,
        startOffset: Double,
        endOffset: Double
    ) {
        guard let itemIndex = items.firstIndex(where: { $0.id == itemID }),
              !isLockedForEditing(items[itemIndex]),
              var program = items[itemIndex].karaoke,
              let unitIndex = program.units.firstIndex(where: { $0.id == unitID }),
              startOffset.isFinite,
              endOffset.isFinite,
              endOffset > startOffset else {
            return
        }
        let oldItems = items
        let oldSelectedIDs = selectedIDs
        program.units[unitIndex].startOffset = startOffset
        program.units[unitIndex].endOffset = endOffset
        items[itemIndex].karaoke = program
        registerUndo(
            label: stropheLocalizedString("karaoke_edit_timing"),
            oldItems: oldItems,
            oldSelectedIDs: oldSelectedIDs
        )
        notifyChange()
    }

    static func mergedKaraokeProgram(
        from orderedItems: [SubtitleItem],
        mergedText: String,
        mergedStartTime: Double,
        mergedEndTime: Double
    ) -> KaraokeProgram? {
        guard let firstProgram = orderedItems.compactMap(\.karaoke).first else {
            return nil
        }
        var characterBase = 0
        var mergedUnits: [KaraokeTimingUnit] = []

        for item in orderedItems {
            let cleanedText = item.text
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
            defer { characterBase += Array(cleanedText).count }
            guard let itemStart = item.startTime,
                  let itemEnd = item.endTime,
                  itemEnd > itemStart else {
                continue
            }
            let itemDuration = itemEnd - itemStart
            let program: KaraokeProgram?
            if let existing = item.karaoke {
                program = existing.reconciled(
                    to: cleanedText,
                    cueDuration: itemDuration
                )
            } else {
                program = KaraokeProgram.evenlyTimed(
                    text: cleanedText,
                    duration: itemDuration,
                    template: firstProgram.template
                )
            }
            guard let program else { continue }

            for unit in program.units {
                var merged = unit
                merged.characterStart += characterBase
                merged.startOffset += itemStart - mergedStartTime
                merged.endOffset += itemStart - mergedStartTime
                mergedUnits.append(merged)
            }
        }

        return KaraokeProgram(
            textSnapshot: mergedText,
            units: mergedUnits,
            template: firstProgram.template,
            isEnabled: orderedItems.contains {
                $0.karaoke?.isEnabled == true
            }
        ).reconciled(
            to: mergedText,
            cueDuration: max(0.000_001, mergedEndTime - mergedStartTime)
        )
    }
}
