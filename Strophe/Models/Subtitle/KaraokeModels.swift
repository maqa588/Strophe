//
//  KaraokeModels.swift
//  Strophe
//
//  Persistent, renderer-independent karaoke timing and template data.
//

import Foundation

nonisolated enum KaraokeTimingSource: String, Codable, Sendable, Equatable, Hashable {
    case forcedAlignment
    case ass
    case manual
    case generated
}

nonisolated enum KaraokeRevealMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case step
    case sweep
}

nonisolated enum KaraokeTemplatePreset: String, Codable, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case classicStep
    case classicSweep
    case pop
    case glow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classicStep:
            return stropheLocalizedString("karaoke_template_classic_step")
        case .classicSweep:
            return stropheLocalizedString("karaoke_template_classic_sweep")
        case .pop:
            return stropheLocalizedString("karaoke_template_pop")
        case .glow:
            return stropheLocalizedString("karaoke_template_glow")
        }
    }
}

/// A small declarative effect description. The renderer compiles this value
/// into cached layers; it is never interpreted as source code.
nonisolated struct KaraokeTemplateConfiguration: Codable, Sendable, Equatable, Hashable {
    var preset: KaraokeTemplatePreset
    var revealMode: KaraokeRevealMode
    /// RGBA in #RRGGBBAA form.
    var inactiveColorHex: String
    /// RGBA in #RRGGBBAA form.
    var activeColorHex: String
    /// Maximum scale reached at the middle of an active unit.
    var popScale: Double
    /// Blur radius in source-video points.
    var glowRadius: Double
    var glowIntensity: Double

    static let classicStep = KaraokeTemplateConfiguration(
        preset: .classicStep,
        revealMode: .step,
        inactiveColorHex: "#A8A8A8FF",
        activeColorHex: "#00DCEFFF",
        popScale: 1,
        glowRadius: 0,
        glowIntensity: 0
    )

    static let classicSweep = KaraokeTemplateConfiguration(
        preset: .classicSweep,
        revealMode: .sweep,
        inactiveColorHex: "#A8A8A8FF",
        activeColorHex: "#00DCEFFF",
        popScale: 1,
        glowRadius: 0,
        glowIntensity: 0
    )

    static let pop = KaraokeTemplateConfiguration(
        preset: .pop,
        revealMode: .sweep,
        inactiveColorHex: "#B0B0B0FF",
        activeColorHex: "#FFD84DFF",
        popScale: 1.16,
        glowRadius: 0,
        glowIntensity: 0
    )

    static let glow = KaraokeTemplateConfiguration(
        preset: .glow,
        revealMode: .sweep,
        inactiveColorHex: "#9A9A9AFF",
        activeColorHex: "#FFFFFFFF",
        popScale: 1.04,
        glowRadius: 10,
        glowIntensity: 0.9
    )

    static func preset(_ preset: KaraokeTemplatePreset) -> KaraokeTemplateConfiguration {
        switch preset {
        case .classicStep: return .classicStep
        case .classicSweep: return .classicSweep
        case .pop: return .pop
        case .glow: return .glow
        }
    }

    mutating func applyPreset(_ preset: KaraokeTemplatePreset) {
        self = Self.preset(preset)
    }

    func maximumOutset(
        maxUnitWidth: Double,
        maxUnitHeight: Double
    ) -> Double {
        let halfMaximumDimension =
            max(
                max(0, maxUnitWidth),
                max(0, maxUnitHeight)
            ) / 2
        let popOutset = max(0, popScale - 1) * halfMaximumDimension
        let glowOutset = max(0, glowRadius) * 3
        return ceil(popOutset + glowOutset)
    }
}

nonisolated struct KaraokeTimingUnit: Identifiable, Codable, Sendable, Equatable, Hashable {
    var id: UUID
    /// Snapshot of the visible grapheme sequence covered by this unit.
    var text: String
    /// Offset and length in Swift Character (extended grapheme cluster) units.
    var characterStart: Int
    var characterLength: Int
    /// Times are relative to the parent cue start and retain sub-frame precision.
    var startOffset: Double
    var endOffset: Double
    var source: KaraokeTimingSource
    var confidence: Double?

    init(
        id: UUID = UUID(),
        text: String,
        characterStart: Int,
        characterLength: Int,
        startOffset: Double,
        endOffset: Double,
        source: KaraokeTimingSource,
        confidence: Double? = nil
    ) {
        self.id = id
        self.text = text
        self.characterStart = characterStart
        self.characterLength = characterLength
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.source = source
        self.confidence = confidence
    }

    var characterEnd: Int {
        characterStart + characterLength
    }

    var duration: Double {
        max(0, endOffset - startOffset)
    }

    func progress(at cueLocalTime: Double) -> Double {
        guard cueLocalTime.isFinite else { return 0 }
        guard endOffset > startOffset else {
            return cueLocalTime >= startOffset ? 1 : 0
        }
        return min(max((cueLocalTime - startOffset) / (endOffset - startOffset), 0), 1)
    }
}

/// Converts authored word timing into adjacent editor cells while preserving
/// the complete cue time domain. Leading/trailing silence belongs to the first
/// and last visual cells, and silence between units is divided at its midpoint.
/// Stored word timing is never changed by this layout-only calculation.
nonisolated enum KaraokeTimelineLayout {
    static func displaySpans(
        for units: [KaraokeTimingUnit],
        cueDuration: Double
    ) -> [ClosedRange<Double>] {
        guard !units.isEmpty,
            cueDuration.isFinite,
            cueDuration > 0
        else {
            return []
        }
        guard units.count > 1 else {
            return [0...cueDuration]
        }

        let epsilon = min(
            0.000_001,
            cueDuration / Double(max(1, units.count * 4))
        )
        var boundaries = [0.0]
        boundaries.reserveCapacity(units.count + 1)

        for index in 0..<(units.count - 1) {
            let rawMidpoint = (units[index].endOffset + units[index + 1].startOffset) / 2
            guard let previousBoundary = boundaries.last else { return [] }
            let lowerBound = previousBoundary + epsilon
            let remainingIntervals = units.count - index - 1
            let upperBound =
                cueDuration
                - Double(remainingIntervals) * epsilon
            let finiteMidpoint =
                rawMidpoint.isFinite
                ? rawMidpoint
                : lowerBound
            boundaries.append(
                min(
                    max(finiteMidpoint, lowerBound),
                    max(lowerBound, upperBound)
                )
            )
        }
        boundaries.append(cueDuration)

        return units.indices.map {
            boundaries[$0]...boundaries[$0 + 1]
        }
    }
}

nonisolated struct KaraokeProgram: Codable, Sendable, Equatable, Hashable {
    static let currentVersion = 2

    var version: Int
    /// The text against which Character ranges were authored.
    var textSnapshot: String
    var units: [KaraokeTimingUnit]
    var template: KaraokeTemplateConfiguration
    /// Presentation can be disabled without discarding aligned word timing.
    var isEnabled: Bool

    init(
        version: Int = KaraokeProgram.currentVersion,
        textSnapshot: String,
        units: [KaraokeTimingUnit],
        template: KaraokeTemplateConfiguration = .classicSweep,
        isEnabled: Bool = true
    ) {
        self.version = version
        self.textSnapshot = textSnapshot
        self.units = units
        self.template = template
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case textSnapshot
        case units
        case template
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version =
            try container.decodeIfPresent(
                Int.self,
                forKey: .version
            ) ?? Self.currentVersion
        textSnapshot = try container.decode(String.self, forKey: .textSnapshot)
        units = try container.decode([KaraokeTimingUnit].self, forKey: .units)
        template =
            try container.decodeIfPresent(
                KaraokeTemplateConfiguration.self,
                forKey: .template
            ) ?? .classicSweep
        // Programs saved before presentation-state separation were active.
        isEnabled =
            try container.decodeIfPresent(
                Bool.self,
                forKey: .isEnabled
            ) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(textSnapshot, forKey: .textSnapshot)
        try container.encode(units, forKey: .units)
        try container.encode(template, forKey: .template)
        try container.encode(isEnabled, forKey: .isEnabled)
    }

    static func fromAlignedWords(
        _ words: [SubtitleWordTiming],
        cueText: String,
        cueStartTime: Double,
        cueEndTime: Double? = nil,
        template: KaraokeTemplateConfiguration = .classicSweep,
        isEnabled: Bool = true
    ) -> KaraokeProgram? {
        guard !words.isEmpty else { return nil }
        let characters = Array(cueText)
        var searchStart = 0
        var mappedUnits: [KaraokeTimingUnit] = []

        for word in words.sorted(by: {
            $0.startTime == $1.startTime
                ? $0.endTime < $1.endTime
                : $0.startTime < $1.startTime
        }) {
            let visibleText = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let wordCharacters = Array(visibleText)
            guard !wordCharacters.isEmpty,
                let range = find(
                    wordCharacters,
                    in: characters,
                    startingAt: searchStart
                )
            else {
                continue
            }

            mappedUnits.append(
                KaraokeTimingUnit(
                    text: String(characters[range]),
                    characterStart: range.lowerBound,
                    characterLength: range.count,
                    startOffset: word.startTime - cueStartTime,
                    endOffset: word.endTime - cueStartTime,
                    source: .forcedAlignment,
                    confidence: word.confidence
                )
            )
            searchStart = range.upperBound
        }

        guard !mappedUnits.isEmpty else { return nil }
        mappedUnits = repairingMissingVisibleCharacters(
            in: characters,
            mappedUnits: mappedUnits
        )
        let program = KaraokeProgram(
            textSnapshot: cueText,
            units: mappedUnits,
            template: template,
            isEnabled: isEnabled
        )
        let inferredDuration =
            mappedUnits
            .map(\.endOffset)
            .filter(\.isFinite)
            .max() ?? 0
        let cueDuration =
            cueEndTime.map { $0 - cueStartTime }
            .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? inferredDuration
        return program.repairingInvalidTiming(cueDuration: cueDuration)
    }

    /// Forced aligners occasionally omit a grapheme even though the supplied
    /// transcript contains it. Keep the transcript authoritative: synthesize
    /// timing only for uncovered visible graphemes and retain the aligner's
    /// original units unchanged whenever there is an actual time gap to use.
    private static func repairingMissingVisibleCharacters(
        in characters: [Character],
        mappedUnits: [KaraokeTimingUnit]
    ) -> [KaraokeTimingUnit] {
        let covered = Set(
            mappedUnits.flatMap { unit in
                Array(unit.characterStart..<unit.characterEnd)
            }
        )
        let missingIndices = characters.indices.filter {
            !characters[$0].isWhitespace && !covered.contains($0)
        }
        guard !missingIndices.isEmpty else { return mappedUnits }

        var missingRuns: [Range<Int>] = []
        var runStart = missingIndices[0]
        var previous = missingIndices[0]
        for index in missingIndices.dropFirst() {
            if index == previous + 1 {
                previous = index
            } else {
                missingRuns.append(runStart..<(previous + 1))
                runStart = index
                previous = index
            }
        }
        missingRuns.append(runStart..<(previous + 1))

        var repaired = mappedUnits.sorted {
            $0.characterStart == $1.characterStart
                ? $0.startOffset < $1.startOffset
                : $0.characterStart < $1.characterStart
        }

        for run in missingRuns {
            let precedingIndex = repaired.indices
                .filter { repaired[$0].characterEnd <= run.lowerBound }
                .max(by: {
                    repaired[$0].characterEnd < repaired[$1].characterEnd
                })
            let followingIndex = repaired.indices
                .filter { repaired[$0].characterStart >= run.upperBound }
                .min(by: {
                    repaired[$0].characterStart < repaired[$1].characterStart
                })

            let precedingEnd = precedingIndex.map { repaired[$0].endOffset }
            let followingStart = followingIndex.map { repaired[$0].startOffset }
            let count = run.count
            let inferredStart: Double
            let inferredEnd: Double

            if let precedingEnd, let followingStart,
                followingStart > precedingEnd + 0.000_001
            {
                // A genuine hole between aligned neighbours is the strongest
                // evidence for where the omitted transcript grapheme belongs.
                inferredStart = precedingEnd
                inferredEnd = followingStart
            } else if let precedingIndex {
                // Adjacent/overlapping aligner output leaves no free interval.
                // Split the tail of the preceding unit so the repaired program
                // stays ordered and never introduces overlapping timing.
                let originalEnd = repaired[precedingIndex].endOffset
                let duration = max(
                    0.000_001,
                    originalEnd - repaired[precedingIndex].startOffset
                )
                let allocation = duration * Double(count) / Double(count + 1)
                inferredEnd = originalEnd
                inferredStart = originalEnd - allocation
                repaired[precedingIndex].endOffset = inferredStart
            } else if let followingIndex {
                // Prefix omission: use available cue-leading time, or split the
                // head of the first aligned unit when it starts at cue zero.
                let originalStart = repaired[followingIndex].startOffset
                if originalStart > 0.000_001 {
                    inferredStart = 0
                    inferredEnd = originalStart
                } else {
                    let originalEnd = repaired[followingIndex].endOffset
                    let duration = max(
                        0.000_001,
                        originalEnd - originalStart
                    )
                    let allocation = duration * Double(count) / Double(count + 1)
                    inferredStart = originalStart
                    inferredEnd = originalStart + allocation
                    repaired[followingIndex].startOffset = inferredEnd
                }
            } else {
                // `mappedUnits` is known to be non-empty, so this is only a
                // defensive fallback for malformed character ranges.
                inferredStart = 0
                inferredEnd = max(0.001, 0.1 * Double(count))
            }

            let duration = max(
                0.001 * Double(count),
                inferredEnd - inferredStart
            )
            let unitDuration = duration / Double(count)
            for (offset, characterIndex) in run.enumerated() {
                repaired.append(
                    KaraokeTimingUnit(
                        text: String(characters[characterIndex]),
                        characterStart: characterIndex,
                        characterLength: 1,
                        startOffset: inferredStart + Double(offset) * unitDuration,
                        endOffset: inferredStart + Double(offset + 1) * unitDuration,
                        source: .generated
                    )
                )
            }
            repaired.sort {
                $0.characterStart == $1.characterStart
                    ? $0.startOffset < $1.startOffset
                    : $0.characterStart < $1.characterStart
            }
        }

        return repaired
    }

    static func evenlyTimed(
        text: String,
        duration: Double,
        template: KaraokeTemplateConfiguration = .classicSweep
    ) -> KaraokeProgram? {
        let characters = Array(text)
        let visibleIndices = characters.indices.filter {
            !characters[$0].isWhitespace
        }
        guard !visibleIndices.isEmpty, duration.isFinite, duration > 0 else {
            return nil
        }

        let unitDuration = duration / Double(visibleIndices.count)
        let units = visibleIndices.enumerated().map { order, characterIndex in
            KaraokeTimingUnit(
                text: String(characters[characterIndex]),
                characterStart: characterIndex,
                characterLength: 1,
                startOffset: Double(order) * unitDuration,
                endOffset: Double(order + 1) * unitDuration,
                source: .generated
            )
        }
        return KaraokeProgram(
            textSnapshot: text,
            units: units,
            template: template
        )
    }

    /// Keeps units whose original graphemes survive contiguously in the edited
    /// text. New or replaced graphemes intentionally remain untimed and are
    /// surfaced by diagnostics instead of receiving invented timing.
    func remapped(to newText: String) -> KaraokeProgram {
        guard newText != textSnapshot else { return self }
        let oldCharacters = Array(textSnapshot)
        let newCharacters = Array(newText)
        let mapping = Self.longestCommonSubsequenceMapping(
            old: oldCharacters,
            new: newCharacters
        )

        let remappedUnits = units.compactMap { unit -> KaraokeTimingUnit? in
            guard unit.characterStart >= 0,
                unit.characterLength > 0,
                unit.characterEnd <= oldCharacters.count
            else {
                return nil
            }
            let oldIndices = Array(unit.characterStart..<unit.characterEnd)
            let mapped = oldIndices.compactMap { mapping[$0] }
            guard mapped.count == oldIndices.count,
                zip(mapped, mapped.dropFirst()).allSatisfy({ $1 == $0 + 1 }),
                let first = mapped.first
            else {
                return nil
            }

            var updated = unit
            updated.characterStart = first
            updated.characterLength = mapped.count
            updated.text = String(newCharacters[first..<(first + mapped.count)])
            return updated
        }

        var updated = self
        updated.textSnapshot = newText
        updated.units = remappedUnits
        return updated
    }

    /// Reconciles stored timing with the cue's current text and duration.
    ///
    /// Subtitle edits treat the visible transcript as authoritative. Surviving
    /// aligned units keep their identity and timing, missing graphemes receive a
    /// generated interval, and every resulting interval is made safe for both
    /// the editor and renderer.
    func reconciled(
        to cueText: String,
        cueDuration: Double
    ) -> KaraokeProgram? {
        guard cueDuration.isFinite, cueDuration > 0 else { return nil }
        let characters = Array(cueText)
        guard characters.contains(where: { !$0.isWhitespace }) else {
            return nil
        }

        var updated = remapped(to: cueText)
        if updated.units.isEmpty {
            guard
                var fallback = Self.evenlyTimed(
                    text: cueText,
                    duration: cueDuration,
                    template: template
                )
            else {
                return nil
            }
            fallback.isEnabled = isEnabled
            return fallback
        }

        updated.textSnapshot = cueText
        updated.units = Self.repairingMissingVisibleCharacters(
            in: characters,
            mappedUnits: updated.units
        )
        return updated.repairingInvalidTiming(cueDuration: cueDuration)
    }

    func shiftingOffsets(by delta: Double) -> KaraokeProgram {
        guard delta.isFinite, abs(delta) > 0.000_000_1 else { return self }
        var updated = self
        updated.units = units.map { unit in
            var shifted = unit
            shifted.startOffset += delta
            shifted.endOffset += delta
            return shifted
        }
        return updated
    }

    func scalingOffsets(by factor: Double) -> KaraokeProgram {
        guard factor.isFinite, factor > 0 else { return self }
        var updated = self
        updated.units = units.map { unit in
            var scaled = unit
            scaled.startOffset *= factor
            scaled.endOffset *= factor
            return scaled
        }
        return updated
    }

    func split(
        atCharacterOffset characterOffset: Int,
        timeOffset: Double,
        cueDuration: Double,
        leftText: String,
        rightText: String
    ) -> (left: KaraokeProgram?, right: KaraokeProgram?) {
        let safeCharacterOffset = min(
            max(0, characterOffset),
            Array(textSnapshot).count
        )
        var leftUnits: [KaraokeTimingUnit] = []
        var rightUnits: [KaraokeTimingUnit] = []

        for unit in units {
            if unit.characterEnd <= safeCharacterOffset {
                leftUnits.append(unit)
                continue
            }
            if unit.characterStart >= safeCharacterOffset {
                var right = unit
                right.characterStart -= safeCharacterOffset
                right.startOffset -= timeOffset
                right.endOffset -= timeOffset
                rightUnits.append(right)
                continue
            }

            let leftCount = safeCharacterOffset - unit.characterStart
            let rightCount = unit.characterLength - leftCount
            guard leftCount > 0, rightCount > 0 else { continue }
            let duration = max(0, unit.endOffset - unit.startOffset)
            let proportionalBoundary =
                unit.startOffset
                + duration * Double(leftCount) / Double(unit.characterLength)
            let boundary = min(
                max(timeOffset, unit.startOffset),
                unit.endOffset
            )
            let resolvedBoundary =
                boundary > unit.startOffset && boundary < unit.endOffset
                ? boundary
                : proportionalBoundary

            var left = unit
            left.id = UUID()
            left.characterLength = leftCount
            left.text = String(Array(unit.text).prefix(leftCount))
            left.endOffset = resolvedBoundary
            leftUnits.append(left)

            var right = unit
            right.id = UUID()
            right.characterStart = 0
            right.characterLength = rightCount
            right.text = String(Array(unit.text).suffix(rightCount))
            right.startOffset = resolvedBoundary - timeOffset
            right.endOffset = unit.endOffset - timeOffset
            rightUnits.append(right)
        }

        let safeTimeOffset = min(max(0, timeOffset), cueDuration)
        let left = KaraokeProgram(
            textSnapshot: leftText,
            units: leftUnits,
            template: template,
            isEnabled: isEnabled
        ).reconciled(
            to: leftText,
            cueDuration: max(0.000_001, safeTimeOffset)
        )
        let right = KaraokeProgram(
            textSnapshot: rightText,
            units: rightUnits,
            template: template,
            isEnabled: isEnabled
        ).reconciled(
            to: rightText,
            cueDuration: max(0.000_001, cueDuration - safeTimeOffset)
        )
        return (left, right)
    }

    func extracting(
        characterRange: Range<Int>,
        cueStartOffset: Double,
        cueDuration: Double,
        text: String
    ) -> KaraokeProgram? {
        guard !characterRange.isEmpty else { return nil }
        let extractedUnits = units.compactMap { unit -> KaraokeTimingUnit? in
            let unitRange = unit.characterStart..<unit.characterEnd
            guard characterRange.contains(unitRange.lowerBound),
                characterRange.contains(unitRange.upperBound - 1)
            else {
                return nil
            }
            var extracted = unit
            extracted.characterStart -= characterRange.lowerBound
            extracted.startOffset -= cueStartOffset
            extracted.endOffset -= cueStartOffset
            return extracted
        }
        return KaraokeProgram(
            textSnapshot: text,
            units: extractedUnits,
            template: template,
            isEnabled: isEnabled
        ).reconciled(to: text, cueDuration: cueDuration)
    }

    func validUnits(for text: String, cueDuration: Double) -> [KaraokeTimingUnit] {
        let characterCount = Array(text).count
        return units.filter {
            $0.characterStart >= 0
                && $0.characterLength > 0
                && $0.characterEnd <= characterCount
                && $0.startOffset.isFinite
                && $0.endOffset.isFinite
                && $0.endOffset > $0.startOffset
                && $0.endOffset > 0
                && $0.startOffset < cueDuration
        }
    }

    /// Produces a render- and edit-safe timeline while retaining every unit's
    /// identity, source and transcript range. Good aligner output is returned
    /// byte-for-byte unchanged. Pathological zero-duration, overlapping or
    /// out-of-cue timestamps are repaired from their temporal centres.
    func repairingInvalidTiming(cueDuration: Double) -> KaraokeProgram {
        guard cueDuration.isFinite, cueDuration > 0, !units.isEmpty else {
            return self
        }
        let ordered = units.sorted {
            $0.characterStart == $1.characterStart
                ? $0.startOffset < $1.startOffset
                : $0.characterStart < $1.characterStart
        }
        var previousEnd = -Double.infinity
        let requiresRepair = ordered.contains { unit in
            let invalid =
                !unit.startOffset.isFinite
                || !unit.endOffset.isFinite
                || unit.endOffset <= unit.startOffset
                || unit.startOffset < 0
                || unit.endOffset > cueDuration
                || unit.startOffset < previousEnd - 0.000_001
            if unit.endOffset.isFinite {
                previousEnd = max(previousEnd, unit.endOffset)
            }
            return invalid
        }
        guard requiresRepair else { return self }

        let count = ordered.count
        let minimumSpacing = max(
            0.000_001,
            min(0.02, cueDuration / Double(max(2, count * 2)))
        )
        var centers = ordered.enumerated().map { index, unit -> Double in
            guard unit.startOffset.isFinite, unit.endOffset.isFinite else {
                return cueDuration * (Double(index) + 0.5) / Double(count)
            }
            return min(
                cueDuration,
                max(0, (unit.startOffset + unit.endOffset) / 2)
            )
        }

        // Clamp every centre into a slot that leaves room for all neighbours,
        // then enforce monotonicity in both directions.
        for index in centers.indices {
            let lower = minimumSpacing * (Double(index) + 0.5)
            let upper =
                cueDuration
                - minimumSpacing * (Double(count - index) - 0.5)
            centers[index] = min(max(centers[index], lower), max(lower, upper))
            if index > 0 {
                centers[index] = max(
                    centers[index],
                    centers[index - 1] + minimumSpacing
                )
            }
        }
        if count > 1 {
            for index in stride(from: count - 2, through: 0, by: -1) {
                centers[index] = min(
                    centers[index],
                    centers[index + 1] - minimumSpacing
                )
            }
        }

        var boundaries = Array(repeating: 0.0, count: count + 1)
        let rawFirstStart =
            ordered[0].startOffset.isFinite
            ? ordered[0].startOffset
            : 0
        boundaries[0] = max(
            0,
            min(rawFirstStart, centers[0] - minimumSpacing / 2)
        )
        if count > 1 {
            for index in 1..<count {
                boundaries[index] = (centers[index - 1] + centers[index]) / 2
            }
        }
        let rawLastEnd =
            ordered[count - 1].endOffset.isFinite
            ? ordered[count - 1].endOffset
            : cueDuration
        boundaries[count] = min(
            cueDuration,
            max(rawLastEnd, centers[count - 1] + minimumSpacing / 2)
        )

        var repaired = self
        repaired.units = ordered.enumerated().map { index, unit in
            var updated = unit
            updated.startOffset = boundaries[index]
            updated.endOffset = max(
                boundaries[index] + 0.000_001,
                boundaries[index + 1]
            )
            return updated
        }
        return repaired
    }

    private static func find(
        _ needle: [Character],
        in haystack: [Character],
        startingAt start: Int
    ) -> Range<Int>? {
        guard !needle.isEmpty, start < haystack.count else { return nil }
        let lastStart = haystack.count - needle.count
        guard lastStart >= start else { return nil }
        for candidate in start...lastStart {
            if Array(haystack[candidate..<(candidate + needle.count)]) == needle {
                return candidate..<(candidate + needle.count)
            }
        }
        return nil
    }

    private static func longestCommonSubsequenceMapping(
        old: [Character],
        new: [Character]
    ) -> [Int: Int] {
        guard !old.isEmpty, !new.isEmpty else { return [:] }
        var lengths = Array(
            repeating: Array(repeating: 0, count: new.count + 1),
            count: old.count + 1
        )
        for oldIndex in old.indices.reversed() {
            for newIndex in new.indices.reversed() {
                lengths[oldIndex][newIndex] =
                    old[oldIndex] == new[newIndex]
                    ? lengths[oldIndex + 1][newIndex + 1] + 1
                    : max(
                        lengths[oldIndex + 1][newIndex],
                        lengths[oldIndex][newIndex + 1]
                    )
            }
        }

        var mapping: [Int: Int] = [:]
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count, newIndex < new.count {
            if old[oldIndex] == new[newIndex] {
                mapping[oldIndex] = newIndex
                oldIndex += 1
                newIndex += 1
            } else if lengths[oldIndex + 1][newIndex] >= lengths[oldIndex][newIndex + 1] {
                oldIndex += 1
            } else {
                newIndex += 1
            }
        }
        return mapping
    }
}

nonisolated enum KaraokeDiagnosticSeverity: String, Sendable, Equatable, Hashable {
    case warning
    case error
}

nonisolated struct KaraokeDiagnostic: Identifiable, Sendable, Equatable, Hashable {
    enum Code: String, Sendable, Equatable, Hashable {
        case textSnapshotMismatch
        case invalidCharacterRange
        case textMismatch
        case invalidTime
        case outsideCue
        case overlappingCharacters
        case overlappingTime
        case uncoveredText
    }

    var id: String {
        "\(code.rawValue):\(unitID?.uuidString ?? "cue")"
    }

    var code: Code
    var severity: KaraokeDiagnosticSeverity
    var unitID: UUID?
    var message: String
}

nonisolated enum KaraokeTimingDiagnostics {
    static func validate(
        program: KaraokeProgram,
        cueText: String,
        cueDuration: Double
    ) -> [KaraokeDiagnostic] {
        let characters = Array(cueText)
        var diagnostics: [KaraokeDiagnostic] = []
        var covered = Set<Int>()

        if program.textSnapshot != cueText {
            diagnostics.append(
                KaraokeDiagnostic(
                    code: .textSnapshotMismatch,
                    severity: .warning,
                    message: stropheLocalizedString("karaoke_diagnostic_text_changed")
                )
            )
        }

        for unit in program.units.sorted(by: {
            $0.characterStart == $1.characterStart
                ? $0.startOffset < $1.startOffset
                : $0.characterStart < $1.characterStart
        }) {
            guard unit.characterStart >= 0,
                unit.characterLength > 0,
                unit.characterEnd <= characters.count
            else {
                diagnostics.append(
                    KaraokeDiagnostic(
                        code: .invalidCharacterRange,
                        severity: .error,
                        unitID: unit.id,
                        message: stropheLocalizedString("karaoke_diagnostic_invalid_range")
                    )
                )
                continue
            }

            let resolvedText = String(
                characters[unit.characterStart..<unit.characterEnd]
            )
            if resolvedText != unit.text {
                diagnostics.append(
                    KaraokeDiagnostic(
                        code: .textMismatch,
                        severity: .warning,
                        unitID: unit.id,
                        message: stropheLocalizedString("karaoke_diagnostic_text_mismatch")
                    )
                )
            }

            if !unit.startOffset.isFinite
                || !unit.endOffset.isFinite
                || unit.endOffset <= unit.startOffset
            {
                diagnostics.append(
                    KaraokeDiagnostic(
                        code: .invalidTime,
                        severity: .error,
                        unitID: unit.id,
                        message: stropheLocalizedString("karaoke_diagnostic_invalid_time")
                    )
                )
            } else if unit.startOffset < 0 || unit.endOffset > cueDuration + 0.000_001 {
                diagnostics.append(
                    KaraokeDiagnostic(
                        code: .outsideCue,
                        severity: .warning,
                        unitID: unit.id,
                        message: stropheLocalizedString("karaoke_diagnostic_outside_cue")
                    )
                )
            }

            let range = unit.characterStart..<unit.characterEnd
            if range.contains(where: { covered.contains($0) }) {
                diagnostics.append(
                    KaraokeDiagnostic(
                        code: .overlappingCharacters,
                        severity: .error,
                        unitID: unit.id,
                        message: stropheLocalizedString("karaoke_diagnostic_overlapping_text")
                    )
                )
            }
            covered.formUnion(range)

        }

        let validTimedUnits = program.units
            .filter {
                $0.startOffset.isFinite
                    && $0.endOffset.isFinite
                    && $0.endOffset > $0.startOffset
            }
            .sorted {
                $0.startOffset == $1.startOffset
                    ? $0.endOffset < $1.endOffset
                    : $0.startOffset < $1.startOffset
            }
        var furthestEndingUnit: KaraokeTimingUnit?
        for unit in validTimedUnits {
            if let furthestEndingUnit,
                unit.startOffset < furthestEndingUnit.endOffset - 0.000_001
            {
                diagnostics.append(
                    KaraokeDiagnostic(
                        code: .overlappingTime,
                        severity: .warning,
                        unitID: unit.id,
                        message: stropheLocalizedString("karaoke_diagnostic_overlapping_time")
                    )
                )
            }
            if furthestEndingUnit == nil
                || unit.endOffset > (furthestEndingUnit?.endOffset ?? -.infinity)
            {
                furthestEndingUnit = unit
            }
        }

        let uncoveredVisibleCharacters = characters.indices.contains {
            !characters[$0].isWhitespace && !covered.contains($0)
        }
        if uncoveredVisibleCharacters {
            diagnostics.append(
                KaraokeDiagnostic(
                    code: .uncoveredText,
                    severity: .warning,
                    message: stropheLocalizedString("karaoke_diagnostic_uncovered_text")
                )
            )
        }
        return diagnostics
    }
}
