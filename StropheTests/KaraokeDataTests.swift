import XCTest
import Combine
@testable import Strophe

final class KaraokeDataTests: XCTestCase {
    @MainActor
    func testASSKaraokeTagsBecomeEditableTiming() throws {
        let styled = PreservedStyledText.ass(#"{\k20}君{\kf35}の{\ko45}歌"#)
        let program = try XCTUnwrap(ASSKaraokeTimingParser.program(from: styled))

        XCTAssertTrue(program.isEnabled)
        XCTAssertEqual(program.textSnapshot, "君の歌")
        XCTAssertEqual(program.units.map(\.text), ["君", "の", "歌"])
        XCTAssertEqual(program.units.map(\.characterStart), [0, 1, 2])
        XCTAssertEqual(program.units[0].endOffset, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(program.units[2].endOffset, 1.0, accuracy: 0.000_001)
        XCTAssertEqual(program.template.revealMode, .sweep)
        XCTAssertTrue(program.units.allSatisfy { $0.source == .ass })
    }

    @MainActor
    func testCloudSentenceSegmentsRetainWordTimestamps() throws {
        let json = """
            {
              "status": "success",
              "model": "qwen3-asr-1.7b",
              "timestamps_sentence": [
                {"start": 10.0, "end": 11.0, "text": "君の"}
              ],
              "timestamps_word": [
                {"start": 10.1, "end": 10.4, "text": "君"},
                {"start": 10.4, "end": 10.8, "text": "の"}
              ]
            }
            """
        let payload = try JSONDecoder().decode(
            AIBackendClient.CloudTranscriptionPayload.self,
            from: Data(json.utf8)
        )
        let result = try AIBackendClient.cloudResult(from: payload)

        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].words.map(\.text), ["君", "の"])
    }

    func testSegmentationRetainsForcedAlignmentWords() {
        let words = [
            SubtitleWordTiming(text: "君", startTime: 10.1, endTime: 10.4),
            SubtitleWordTiming(text: "の", startTime: 10.4, endTime: 10.7),
        ]

        let segments = SubtitleSegmentation.makeSegments(words: words)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].words, words)
    }

    func testAlignedWordsMapToGraphemeRangesAndRelativeTimes() throws {
        let words = [
            SubtitleWordTiming(text: "君", startTime: 10.1, endTime: 10.4),
            SubtitleWordTiming(text: "の", startTime: 10.4, endTime: 10.7),
            SubtitleWordTiming(text: "こと", startTime: 10.7, endTime: 11.2),
        ]

        let program = try XCTUnwrap(
            KaraokeProgram.fromAlignedWords(
                words,
                cueText: "君のこと",
                cueStartTime: 10
            )
        )

        XCTAssertEqual(program.units.map(\.characterStart), [0, 1, 2])
        XCTAssertEqual(program.units.map(\.characterLength), [1, 1, 2])
        XCTAssertEqual(program.units[0].startOffset, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(program.units[2].endOffset, 1.2, accuracy: 0.000_001)
    }

    func testKaraokeTimelineLayoutAlwaysCoversCompleteCueDuration() throws {
        let base = try XCTUnwrap(
            KaraokeProgram.evenlyTimed(text: "唱歌", duration: 1)
        )
        let unitsWithSilence = base.shiftingOffsets(by: 0.5).units
        let spans = KaraokeTimelineLayout.displaySpans(
            for: unitsWithSilence,
            cueDuration: 2
        )

        XCTAssertEqual(spans.count, unitsWithSilence.count)
        XCTAssertEqual(spans.first?.lowerBound, 0)
        XCTAssertEqual(spans.last?.upperBound, 2)
        XCTAssertEqual(
            spans[0].upperBound,
            spans[1].lowerBound,
            accuracy: 0.000_001
        )

        let singleSpan = KaraokeTimelineLayout.displaySpans(
            for: [unitsWithSilence[0]],
            cueDuration: 3
        )
        XCTAssertEqual(singleSpan, [0...3])
    }

    func testMissingForcedAlignmentCharacterIsInsertedBetweenNeighbours() throws {
        let program = try XCTUnwrap(
            KaraokeProgram.fromAlignedWords(
                [
                    SubtitleWordTiming(
                        text: "才",
                        startTime: 12.0,
                        endTime: 12.3
                    ),
                    SubtitleWordTiming(
                        text: "的",
                        startTime: 12.8,
                        endTime: 13.1
                    ),
                ],
                cueText: "才有的",
                cueStartTime: 10
            )
        )

        XCTAssertEqual(program.units.map(\.text), ["才", "有", "的"])
        XCTAssertEqual(program.units.map(\.characterStart), [0, 1, 2])
        XCTAssertEqual(program.units[1].source, .generated)
        XCTAssertEqual(program.units[1].startOffset, 2.3, accuracy: 0.000_001)
        XCTAssertEqual(program.units[1].endOffset, 2.8, accuracy: 0.000_001)

        let diagnostics = KaraokeTimingDiagnostics.validate(
            program: program,
            cueText: "才有的",
            cueDuration: 4
        )
        XCTAssertFalse(diagnostics.contains { $0.code == .uncoveredText })
        XCTAssertFalse(diagnostics.contains { $0.code == .overlappingTime })
    }

    func testInvalidAlignerTimesAreRepairedWithoutDroppingTranscriptUnits() throws {
        let program = try XCTUnwrap(
            KaraokeProgram.fromAlignedWords(
                [
                    SubtitleWordTiming(
                        text: "偶",
                        startTime: 10.2,
                        endTime: 10.2
                    ),
                    SubtitleWordTiming(
                        text: "尔",
                        startTime: 10.15,
                        endTime: 10.5
                    ),
                    SubtitleWordTiming(
                        text: "错",
                        startTime: 12.2,
                        endTime: 12.2
                    ),
                ],
                cueText: "偶尔出错",
                cueStartTime: 10,
                cueEndTime: 12
            )
        )

        XCTAssertEqual(program.units.map(\.text), ["偶", "尔", "出", "错"])
        XCTAssertTrue(
            zip(program.units, program.units.dropFirst()).allSatisfy {
                $0.endOffset <= $1.startOffset + 0.000_001
            }
        )
        XCTAssertTrue(
            program.units.allSatisfy {
                $0.endOffset > $0.startOffset
                    && $0.startOffset >= 0
                    && $0.endOffset <= 2
            })

        let diagnostics = KaraokeTimingDiagnostics.validate(
            program: program,
            cueText: "偶尔出错",
            cueDuration: 2
        )
        XCTAssertFalse(diagnostics.contains { $0.severity == .error })
        XCTAssertFalse(diagnostics.contains { $0.code == .overlappingTime })
        XCTAssertFalse(diagnostics.contains { $0.code == .uncoveredText })
    }

    @MainActor
    func testKaraokeProgramPersistsInsideSubtitleItem() throws {
        let program = try XCTUnwrap(
            KaraokeProgram.evenlyTimed(text: "唱歌", duration: 2)
        )
        let item = SubtitleItem(
            text: "唱歌",
            startTime: 4,
            endTime: 6,
            karaoke: program
        )

        let encoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(SubtitleItem.self, from: encoded)

        XCTAssertEqual(decoded, item)
    }

    func testLegacyKaraokeProgramDefaultsToEnabledWhenStateIsMissing() throws {
        let program = try XCTUnwrap(
            KaraokeProgram.evenlyTimed(text: "AB", duration: 1)
        )
        let encoded = try JSONEncoder().encode(program)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "isEnabled")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            KaraokeProgram.self,
            from: legacyData
        )

        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.units, program.units)
    }

    func testTextInsertionPreservesSurvivingUnitsAndLeavesNewTextUntimed() throws {
        let original = try XCTUnwrap(
            KaraokeProgram.evenlyTimed(text: "君のこと", duration: 2)
        )

        let edited = original.remapped(to: "ねえ君のこと")
        let diagnostics = KaraokeTimingDiagnostics.validate(
            program: edited,
            cueText: "ねえ君のこと",
            cueDuration: 2
        )

        XCTAssertEqual(edited.units.map(\.characterStart), [2, 3, 4, 5])
        XCTAssertTrue(diagnostics.contains { $0.code == .uncoveredText })
        XCTAssertFalse(diagnostics.contains { $0.severity == .error })
    }

    @MainActor
    func testMovingCuePreservesRelativeTimingAndCueTrimRepairsVisibleTiming() throws {
        var moved = SubtitleItem(
            text: "唱歌",
            startTime: 10,
            endTime: 12,
            karaoke: try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: "唱歌", duration: 2)
            )
        )

        moved.retimeKaraokeForCueChange(
            oldStart: 10,
            oldEnd: 12,
            newStart: 14,
            newEnd: 16
        )
        XCTAssertEqual(moved.karaoke?.units[0].startOffset, 0)

        moved.retimeKaraokeForCueChange(
            oldStart: 14,
            oldEnd: 16,
            newStart: 14.5,
            newEnd: 16
        )
        let trimmed = try XCTUnwrap(moved.karaoke)
        XCTAssertEqual(trimmed.units[0].startOffset, 0, accuracy: 0.000_001)
        XCTAssertTrue(
            trimmed.units.allSatisfy {
                $0.startOffset >= 0
                    && $0.endOffset > $0.startOffset
                    && $0.endOffset <= 1.5
            })
        XCTAssertFalse(
            KaraokeTimingDiagnostics.validate(
                program: trimmed,
                cueText: moved.text,
                cueDuration: 1.5
            ).contains { $0.severity == .error }
        )
    }

    func testInvalidOverlapAndOutOfBoundsAreDiagnosed() {
        let program = KaraokeProgram(
            textSnapshot: "AB",
            units: [
                KaraokeTimingUnit(
                    text: "A",
                    characterStart: 0,
                    characterLength: 1,
                    startOffset: -0.1,
                    endOffset: 0.8,
                    source: .manual
                ),
                KaraokeTimingUnit(
                    text: "B",
                    characterStart: 1,
                    characterLength: 1,
                    startOffset: 0.5,
                    endOffset: 1.5,
                    source: .manual
                ),
            ]
        )

        let diagnostics = KaraokeTimingDiagnostics.validate(
            program: program,
            cueText: "AB",
            cueDuration: 1
        )

        XCTAssertTrue(diagnostics.contains { $0.code == .outsideCue })
        XCTAssertTrue(diagnostics.contains { $0.code == .overlappingTime })
    }

    @MainActor
    func testSplitAndMergeKeepKaraokeTiming() throws {
        let project = SubtitleProject()
        let item = SubtitleItem(
            text: "君のこと",
            startTime: 10,
            endTime: 12,
            karaoke: try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: "君のこと", duration: 2)
            )
        )
        project.items = [item]

        project.splitSubtitle(
            id: item.id,
            at: 11,
            leftText: "君の",
            rightText: "こと"
        )

        XCTAssertEqual(project.items.count, 2)
        XCTAssertEqual(project.items[0].karaoke?.units.count, 2)
        XCTAssertEqual(project.items[1].karaoke?.units.count, 2)
        let rightStart = try XCTUnwrap(
            project.items[1].karaoke?.units.first?.startOffset
        )
        XCTAssertEqual(rightStart, 0, accuracy: 0.000_001)
        for cue in project.items {
            let program = try XCTUnwrap(cue.karaoke)
            let duration =
                try XCTUnwrap(cue.endTime)
                - (cue.startTime ?? 0)
            let spans = KaraokeTimelineLayout.displaySpans(
                for: program.units,
                cueDuration: duration
            )
            XCTAssertEqual(spans.first?.lowerBound, 0)
            XCTAssertEqual(
                try XCTUnwrap(spans.last?.upperBound),
                duration,
                accuracy: 0.000_001
            )
        }

        project.selectedIDs = Set(project.items.map(\.id))
        var mergeItemPublications = 0
        let mergeObservation = project.$items
            .dropFirst()
            .sink { _ in mergeItemPublications += 1 }
        XCTAssertNil(project.mergeSelectedSubtitles())
        XCTAssertEqual(mergeItemPublications, 1)
        withExtendedLifetime(mergeObservation) {}
        XCTAssertEqual(project.items.count, 1)
        XCTAssertEqual(project.items[0].karaoke?.units.count, 4)
        let merged = try XCTUnwrap(project.items.first)
        let mergedProgram = try XCTUnwrap(merged.karaoke)
        let mergedDuration =
            try XCTUnwrap(merged.endTime)
            - (merged.startTime ?? 0)
        let mergedSpans = KaraokeTimelineLayout.displaySpans(
            for: mergedProgram.units,
            cueDuration: mergedDuration
        )
        XCTAssertEqual(mergedSpans.first?.lowerBound, 0)
        XCTAssertEqual(
            try XCTUnwrap(mergedSpans.last?.upperBound),
            mergedDuration,
            accuracy: 0.000_001
        )
    }

    @MainActor
    func testSplitAtNonWordBoundaryKeepsBothCuesRenderSafe() throws {
        let item = SubtitleItem(
            text: "字幕拆分",
            startTime: 10,
            endTime: 14,
            karaoke: try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: "字幕拆分", duration: 4)
            )
        )
        let project = SubtitleProject()
        project.items = [item]

        // The text is split after two graphemes, while the playhead is well
        // inside the third grapheme's original interval.
        project.splitSubtitle(
            id: item.id,
            at: 12.7,
            leftText: "字幕",
            rightText: "拆分"
        )

        XCTAssertEqual(project.items.count, 2)
        for cue in project.items {
            let program = try XCTUnwrap(cue.karaoke)
            let duration = try XCTUnwrap(cue.endTime) - (cue.startTime ?? 0)
            XCTAssertEqual(
                program.units.map(\.text).joined(),
                cue.text
            )
            XCTAssertTrue(
                program.units.allSatisfy {
                    $0.startOffset >= 0
                        && $0.endOffset > $0.startOffset
                        && $0.endOffset <= duration + 0.000_001
                })
            XCTAssertFalse(
                cue.karaokeDiagnostics.contains { $0.severity == .error }
            )
        }
    }

    @MainActor
    func testSplitRejectsTimesThatSnapOntoCueEdges() {
        let item = SubtitleItem(text: "edge", startTime: 0, endTime: 1)
        let project = SubtitleProject()
        project.videoFrameRate = 30
        project.items = [item]

        project.splitSubtitle(
            id: item.id,
            at: 0.001,
            leftText: "ed",
            rightText: "ge"
        )
        project.splitSubtitle(
            id: item.id,
            at: 0.999,
            leftText: "ed",
            rightText: "ge"
        )

        XCTAssertEqual(project.items, [item])
    }

    @MainActor
    func testMergeRejectsStaleSelectionIDs() {
        let first = SubtitleItem(text: "first", startTime: 0, endTime: 1)
        let second = SubtitleItem(text: "second", startTime: 1, endTime: 2)
        let project = SubtitleProject()
        project.items = [first, second]
        project.selectedIDs = [first.id, UUID()]

        XCTAssertNotNil(project.mergeSelectedSubtitles())
        XCTAssertEqual(project.items, [first, second])
    }

    @MainActor
    func testMergeReconcilesUntimedCueTextIntoKaraokeProgram() throws {
        let first = SubtitleItem(
            text: "已有",
            startTime: 1,
            endTime: 2,
            karaoke: try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: "已有", duration: 1)
            )
        )
        let second = SubtitleItem(
            text: "补齐",
            startTime: 2.4,
            endTime: 3.4
        )
        let project = SubtitleProject()
        project.items = [first, second]
        project.selectedIDs = [first.id, second.id]

        XCTAssertNil(project.mergeSelectedSubtitles())

        let merged = try XCTUnwrap(project.items.first)
        let program = try XCTUnwrap(merged.karaoke)
        XCTAssertEqual(merged.text, "已有补齐")
        XCTAssertEqual(program.units.map(\.text).joined(), merged.text)
        XCTAssertTrue(
            program.units.suffix(2).allSatisfy { $0.source == .generated }
        )
        let generatedStart = try XCTUnwrap(
            program.units.suffix(2).first?.startOffset
        )
        XCTAssertEqual(
            generatedStart,
            1.4,
            accuracy: 0.000_001
        )
        XCTAssertFalse(
            merged.karaokeDiagnostics.contains { $0.severity == .error }
        )
    }

    @MainActor
    func testDraggingBothCueEdgesUpdatesStoredKaraokeTiming() throws {
        let item = SubtitleItem(
            text: "左右拖拽",
            startTime: 10,
            endTime: 14,
            karaoke: try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: "左右拖拽", duration: 4)
            )
        )
        let project = SubtitleProject()
        project.items = [item]

        project.updateSubtitleTime(
            id: item.id,
            newStartTime: 10.8,
            newEndTime: 14
        )
        project.updateSubtitleTime(
            id: item.id,
            newStartTime: 10.8,
            newEndTime: 12.6
        )

        let updated = try XCTUnwrap(project.items.first)
        let program = try XCTUnwrap(updated.karaoke)
        let duration = try XCTUnwrap(updated.endTime) - (updated.startTime ?? 0)
        XCTAssertEqual(program.units.map(\.text).joined(), updated.text)
        XCTAssertTrue(
            program.units.allSatisfy {
                $0.startOffset >= 0
                    && $0.endOffset > $0.startOffset
                    && $0.endOffset <= duration + 0.000_001
            })
        XCTAssertFalse(
            updated.karaokeDiagnostics.contains { $0.severity == .error }
        )
        let spans = KaraokeTimelineLayout.displaySpans(
            for: program.units,
            cueDuration: duration
        )
        XCTAssertEqual(spans.first?.lowerBound, 0)
        XCTAssertEqual(
            try XCTUnwrap(spans.last?.upperBound),
            duration,
            accuracy: 0.000_001
        )
    }

    @MainActor
    func testKaraokeTrimPreviewUpdatesEditorAndOverlayBeforeCommit() throws {
        let item = SubtitleItem(
            text: "实时更新",
            startTime: 10,
            endTime: 12,
            karaoke: try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: "实时更新", duration: 2)
            )
        )
        let project = SubtitleProject()
        project.videoFrameRate = 30
        project.items = [item]
        project.selectedIDs = [item.id]
        project.karaokeEditingItemID = item.id

        project.previewKaraokeCueTiming(
            id: item.id,
            newStartTime: 10,
            newEndTime: 14
        )

        XCTAssertEqual(project.items.first, item)
        let preview = try XCTUnwrap(project.karaokeTimingPreviewItem)
        XCTAssertEqual(project.karaokeEditorItem, preview)
        XCTAssertEqual(preview.endTime, 14)
        XCTAssertEqual(
            project.resolvedSubtitleCue(at: 13)?.endTime,
            14
        )

        project.updateSubtitleTime(
            id: item.id,
            newStartTime: 10,
            newEndTime: 14
        )

        XCTAssertNil(project.karaokeTimingPreviewItem)
        XCTAssertEqual(project.items.first, preview)
    }

    @MainActor
    func testScheduledKaraokeTrimPreviewCoalescesAndCannotOverwriteCommit() async throws {
        let item = SubtitleItem(
            text: "最后一帧",
            startTime: 10,
            endTime: 12,
            karaoke: try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: "最后一帧", duration: 2)
            )
        )
        let project = SubtitleProject()
        project.items = [item]

        project.scheduleKaraokeCueTimingPreview(
            id: item.id,
            newStartTime: 10,
            newEndTime: 14
        )
        project.scheduleKaraokeCueTimingPreview(
            id: item.id,
            newStartTime: 10,
            newEndTime: 16
        )
        await Task.yield()

        XCTAssertEqual(project.karaokeTimingPreviewItem?.endTime, 16)

        project.scheduleKaraokeCueTimingPreview(
            id: item.id,
            newStartTime: 10,
            newEndTime: 18
        )
        project.updateSubtitleTime(
            id: item.id,
            newStartTime: 10,
            newEndTime: 15
        )
        await Task.yield()

        XCTAssertNil(project.karaokeTimingPreviewItem)
        XCTAssertEqual(project.items.first?.endTime, 15)
    }

    @MainActor
    func testBatchStretchScalesKaraokeAndRefreshesFullCueLayout() throws {
        let item = SubtitleItem(
            text: "同步拉伸",
            startTime: 1,
            endTime: 3,
            karaoke: try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: "同步拉伸", duration: 2)
            )
        )
        let project = SubtitleProject()
        project.videoFrameRate = 30
        project.items = [item]

        project.stretchSubtitles(
            ids: [item.id],
            factor: 1.5,
            anchor: 0
        )

        let stretched = try XCTUnwrap(project.items.first)
        let program = try XCTUnwrap(stretched.karaoke)
        let duration =
            try XCTUnwrap(stretched.endTime)
            - (stretched.startTime ?? 0)
        XCTAssertEqual(stretched.startTime, 1.5)
        XCTAssertEqual(stretched.endTime, 4.5)
        XCTAssertEqual(program.units.last?.endOffset, 3)
        let spans = KaraokeTimelineLayout.displaySpans(
            for: program.units,
            cueDuration: duration
        )
        XCTAssertEqual(spans.first?.lowerBound, 0)
        XCTAssertEqual(spans.last?.upperBound, 3)
    }

    @MainActor
    func testBatchKaraokeRecognitionPublishesItemsOnlyOnce() throws {
        let first = SubtitleItem(
            text: "批量",
            startTime: 0,
            endTime: 1
        )
        let second = SubtitleItem(
            text: "识别",
            startTime: 1,
            endTime: 2
        )
        let project = SubtitleProject()
        project.items = [first, second]
        let programs = [
            first.id: try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: first.text, duration: 1)
            ),
            second.id: try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: second.text, duration: 1)
            ),
        ]
        var itemPublications = 0
        let observation = project.$items
            .dropFirst()
            .sink { _ in itemPublications += 1 }

        project.applyBatchKaraokePrograms(programs)

        XCTAssertEqual(itemPublications, 1)
        XCTAssertTrue(project.items.allSatisfy { $0.karaoke != nil })
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testTimingUndoRestoresExactKaraokeProgramAfterClampedMove() throws {
        let originalProgram = try XCTUnwrap(
            KaraokeProgram.evenlyTimed(text: "AB", duration: 1.9)
        )
        let item = SubtitleItem(
            text: "AB",
            startTime: 0.1,
            endTime: 2,
            karaoke: originalProgram
        )
        let project = SubtitleProject()
        project.items = [item]
        project.selectedIDs = [item.id]

        project.moveSelectedBlocks(by: -0.5)
        XCTAssertEqual(project.items[0].startTime, 0)

        project.undo()
        XCTAssertEqual(project.items[0].startTime, 0.1)
        XCTAssertEqual(project.items[0].endTime, 2)
        XCTAssertEqual(project.items[0].karaoke, originalProgram)
    }

    @MainActor
    func testBoundaryEditMovesAdjacentEdgesAndRemainsContiguous() throws {
        let program = try XCTUnwrap(
            KaraokeProgram.evenlyTimed(text: "ABC", duration: 3)
        )
        let item = SubtitleItem(
            text: "ABC",
            startTime: 10,
            endTime: 13,
            karaoke: program
        )
        let project = SubtitleProject()
        project.items = [item]

        project.updateKaraokeBoundary(
            itemID: item.id,
            precedingUnitID: program.units[0].id,
            to: 1.35
        )

        let units = try XCTUnwrap(project.items[0].karaoke?.units)
        XCTAssertEqual(units[0].endOffset, 1.35, accuracy: 0.000_001)
        XCTAssertEqual(units[1].startOffset, 1.35, accuracy: 0.000_001)
        XCTAssertEqual(units[1].endOffset, 2, accuracy: 0.000_001)
        XCTAssertEqual(units[2].startOffset, 2, accuracy: 0.000_001)
    }

    @MainActor
    func testDisablingPresentationRetainsTimingAndReenableReusesIt() throws {
        let program = try XCTUnwrap(
            KaraokeProgram.fromAlignedWords(
                [
                    SubtitleWordTiming(
                        text: "唱",
                        startTime: 10.1,
                        endTime: 10.7,
                        confidence: 0.98
                    ),
                    SubtitleWordTiming(
                        text: "歌",
                        startTime: 10.7,
                        endTime: 11.4,
                        confidence: 0.97
                    ),
                ],
                cueText: "唱歌",
                cueStartTime: 10
            )
        )
        let item = SubtitleItem(
            text: "唱歌",
            startTime: 10,
            endTime: 12,
            karaoke: program
        )
        let project = SubtitleProject()
        project.items = [item]
        project.selectedIDs = [item.id]

        project.disableKaraoke(id: item.id)

        let retained = try XCTUnwrap(project.items[0].karaoke)
        XCTAssertFalse(retained.isEnabled)
        XCTAssertEqual(retained.units, program.units)
        XCTAssertNil(project.items[0].activeKaraoke)
        XCTAssertNil(project.resolvedSubtitleCues().first?.karaoke)

        project.enableKaraoke(id: item.id)

        let restored = try XCTUnwrap(project.items[0].activeKaraoke)
        XCTAssertEqual(restored.units, program.units)
        XCTAssertEqual(
            restored.units.map(\.source),
            [.forcedAlignment, .forcedAlignment]
        )
    }

    @MainActor
    func testKaraokeEditorRequiresExplicitActivationAndClosesOnSelectionChange() async throws {
        let first = SubtitleItem(text: "唱歌", startTime: 1, endTime: 3)
        let second = SubtitleItem(text: "下一句", startTime: 3, endTime: 5)
        let project = SubtitleProject()
        project.items = [first, second]
        project.selectedIDs = [first.id]

        XCTAssertNil(project.karaokeEditorItem)
        XCTAssertFalse(project.canToggleKaraokeEditor)

        project.setKaraokeFromBlockAction(
            itemID: first.id,
            isEnabled: true
        )
        XCTAssertTrue(project.canToggleKaraokeEditor)
        XCTAssertNil(project.karaokeEditorItem)

        project.toggleKaraokeEditorForSelection()

        XCTAssertEqual(project.karaokeEditingItemID, first.id)
        XCTAssertEqual(project.karaokeEditorItem?.id, first.id)
        XCTAssertNotNil(project.items[0].activeKaraoke)

        project.selectedIDs = [second.id]
        await Task.yield()

        XCTAssertNil(project.karaokeEditingItemID)
        XCTAssertNil(project.karaokeEditorItem)
        XCTAssertNotNil(
            project.items[0].activeKaraoke,
            "Closing the editor must not discard or disable Karaoke data."
        )
    }

    @MainActor
    func testKaraokeToolbarToggleClosesEditorWithoutDisablingCue() {
        let item = SubtitleItem(text: "AB", startTime: 0, endTime: 2)
        let project = SubtitleProject()
        project.items = [item]
        project.selectedIDs = [item.id]

        project.setKaraokeFromBlockAction(
            itemID: item.id,
            isEnabled: true
        )
        project.toggleKaraokeEditorForSelection()
        project.toggleKaraokeEditorForSelection()

        XCTAssertNil(project.karaokeEditingItemID)
        XCTAssertNotNil(project.items[0].activeKaraoke)
    }

    @MainActor
    func testSelectingEnabledKaraokeCueAutomaticallyOpensEditor() async throws {
        let enabled = SubtitleItem(
            text: "自动打开",
            startTime: 1,
            endTime: 3,
            karaoke: try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: "自动打开", duration: 2)
            )
        )
        let ordinary = SubtitleItem(text: "普通字幕", startTime: 3, endTime: 5)
        let project = SubtitleProject()
        project.items = [enabled, ordinary]

        project.selectedIDs = [enabled.id]
        await Task.yield()
        XCTAssertEqual(project.karaokeEditorItem?.id, enabled.id)

        project.selectedIDs = [ordinary.id]
        await Task.yield()
        XCTAssertNil(project.karaokeEditorItem)
    }

    @MainActor
    func testRapidSelectionChangesCoalesceKaraokeEditorPublication() async throws {
        let first = SubtitleItem(
            text: "第一句",
            startTime: 1,
            endTime: 2,
            karaoke: try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: "第一句", duration: 1)
            )
        )
        let second = SubtitleItem(
            text: "第二句",
            startTime: 2,
            endTime: 3,
            karaoke: try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: "第二句", duration: 1)
            )
        )
        let project = SubtitleProject()
        project.items = [first, second]
        project.karaokeEditorDismissedItemID = first.id

        project.selectedIDs = [first.id]
        project.selectedIDs = [second.id]
        await Task.yield()

        XCTAssertNil(project.karaokeEditorDismissedItemID)
        XCTAssertEqual(project.karaokeEditingItemID, second.id)
    }

    @MainActor
    func testPlayheadAutomaticallySwitchesKaraokeEditorCue() async throws {
        let first = SubtitleItem(
            text: "第一句",
            startTime: 1,
            endTime: 3,
            karaoke: try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: "第一句", duration: 2)
            )
        )
        let second = SubtitleItem(
            text: "第二句",
            startTime: 3,
            endTime: 5,
            karaoke: try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: "第二句", duration: 2)
            )
        )
        let project = SubtitleProject()
        project.items = [first, second]

        project.currentTime = 1.5
        await Task.yield()
        XCTAssertEqual(project.selectedIDs, [first.id])
        XCTAssertEqual(project.karaokeEditorItem?.id, first.id)

        project.currentTime = 3.5
        await Task.yield()
        XCTAssertEqual(project.selectedIDs, [second.id])
        XCTAssertEqual(project.karaokeEditorItem?.id, second.id)

        project.currentTime = 5.5
        await Task.yield()
        XCTAssertEqual(
            project.karaokeEditorItem?.id,
            second.id,
            "A timeline gap should retain the most recently displayed Karaoke panel."
        )
    }

    @MainActor
    func testOrdinaryCueClosesRetainedKaraokePanelButEmptyGapDoesNot() async throws {
        let karaoke = SubtitleItem(
            text: "卡拉",
            startTime: 1,
            endTime: 2,
            karaoke: try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: "卡拉", duration: 1)
            )
        )
        let ordinary = SubtitleItem(
            text: "普通",
            startTime: 4,
            endTime: 5
        )
        let project = SubtitleProject()
        project.items = [karaoke, ordinary]

        project.currentTime = 1.5
        await Task.yield()
        XCTAssertEqual(project.karaokeEditorItem?.id, karaoke.id)

        project.currentTime = 3
        await Task.yield()
        XCTAssertEqual(project.karaokeEditorItem?.id, karaoke.id)

        project.currentTime = 4.5
        await Task.yield()
        XCTAssertNil(project.karaokeEditorItem)
    }

    @MainActor
    func testPlaybackTicksInsideOrdinaryCueDoNotPublishUnchangedKaraokeState() {
        let ordinary = SubtitleItem(
            text: "普通字幕",
            startTime: 1,
            endTime: 3
        )
        let project = SubtitleProject()
        project.items = [ordinary]

        // Establish the current cue and its cache before observing subsequent
        // frame-rate playback updates.
        project.currentTime = 1.1

        var publicationCount = 0
        let cancellable = project.objectWillChange.sink {
            publicationCount += 1
        }

        project.currentTime = 1.2
        project.currentTime = 1.5
        project.currentTime = 2.8

        XCTAssertEqual(
            publicationCount,
            0,
            "A playback tick must not invalidate the editor when Karaoke state is unchanged."
        )
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testMultiSelectionBlockActionBatchEnablesAndDisablesKaraoke() {
        let first = SubtitleItem(text: "第一句", startTime: 1, endTime: 3)
        let second = SubtitleItem(text: "第二句", startTime: 3, endTime: 5)
        let project = SubtitleProject()
        project.items = [first, second]
        project.selectedIDs = [first.id, second.id]

        XCTAssertFalse(project.canToggleKaraokeEditor)
        project.setKaraokeFromBlockAction(
            itemID: first.id,
            isEnabled: true
        )

        XCTAssertNil(project.karaokeEditingItemID)
        XCTAssertTrue(project.items.allSatisfy { $0.activeKaraoke != nil })
        XCTAssertTrue(
            project.isKaraokeEnabledFromBlockAction(itemID: first.id)
        )

        project.setKaraokeFromBlockAction(
            itemID: first.id,
            isEnabled: false
        )

        XCTAssertTrue(project.items.allSatisfy { $0.activeKaraoke == nil })
        XCTAssertFalse(
            project.isKaraokeEnabledFromBlockAction(itemID: first.id)
        )
    }
}
