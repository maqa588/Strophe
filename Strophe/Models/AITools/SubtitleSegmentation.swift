//
//  SubtitleSegmentation.swift
//  Strophe
//

import Foundation

/// A word-level timestamp produced by ForcedAligner.
///
/// Segmentation only reads these values. It never rewrites word-level timing.
nonisolated struct SubtitleWordTiming: Sendable, Equatable {
    let text: String
    let startTime: Double
    let endTime: Double
}

/// Converts aligned words into readable subtitle cues, then repairs the final
/// sentence-level timeline without changing recognized text or word timing.
nonisolated enum SubtitleSegmentation {
    struct Configuration: Sendable {
        var maximumCJKCharacters = 17
        var maximumLatinCharacters = 84
        var targetMaximumDuration = 6.2
        var longSilence = 1.0
    }

    static let defaultContinuityThreshold = 1.0
    static let continuityEnvironmentKey = "STROPHE_SUBTITLE_CONTINUITY_SECONDS"

    static var configuredContinuityThreshold: Double {
        guard let rawValue = ProcessInfo.processInfo.environment[continuityEnvironmentKey],
              let value = Double(rawValue),
              value.isFinite else {
            return defaultContinuityThreshold
        }
        return max(0, value)
    }

    static func makeSegments(
        words: [SubtitleWordTiming],
        configuration: Configuration = Configuration()
    ) -> [AIResultSegment] {
        let orderedWords = words
            .filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    $0.startTime.isFinite && $0.endTime.isFinite
            }
            .sorted {
                $0.startTime == $1.startTime
                    ? $0.endTime < $1.endTime
                    : $0.startTime < $1.startTime
            }

        guard !orderedWords.isEmpty else { return [] }

        // Keep the order intentional: punctuation/long-pause sentences first,
        // DP splitting second, isolated-character repair last.
        let sentences = sentenceSpans(from: orderedWords, longSilence: configuration.longSilence)
        let splitSpans = sentences.flatMap { split($0, configuration: configuration) }
        let repairedSpans = repairIsolatedCJKCharacters(
            in: splitSpans,
            longSilence: configuration.longSilence
        )

        return repairedSpans.compactMap(makeResultSegment)
    }

    /// Makes nearby sentence boundaries continuous. Positive gaps extend the
    /// current cue; small overlaps shorten it. Large pauses remain untouched.
    static func smoothTimeline(
        _ input: [AIResultSegment],
        threshold: Double
    ) -> [AIResultSegment] {
        guard input.count > 1, threshold.isFinite, threshold > 0 else { return input }

        var result = input
        for index in 0..<(result.count - 1) {
            let current = result[index]
            let nextStart = result[index + 1].startTime
            let adjustment = nextStart - current.endTime

            guard abs(adjustment) <= threshold,
                  nextStart > current.startTime else {
                continue
            }

            result[index] = AIResultSegment(
                text: current.text,
                startTime: current.startTime,
                endTime: nextStart
            )
        }
        return result
    }

    // MARK: - Sentence recovery and dynamic-programming splitting

    private struct WordSpan {
        var words: [SubtitleWordTiming]

        var startTime: Double { words.first?.startTime ?? 0 }
        var endTime: Double { words.last?.endTime ?? startTime }
        var duration: Double { max(0, endTime - startTime) }
        var text: String { joinedText(words.map(\.text)) }
    }

    private static func sentenceSpans(
        from words: [SubtitleWordTiming],
        longSilence: Double
    ) -> [WordSpan] {
        var result: [WordSpan] = []
        var buffer: [SubtitleWordTiming] = []

        for (index, word) in words.enumerated() {
            buffer.append(word)
            let nextGap = index + 1 < words.count
                ? words[index + 1].startTime - word.endTime
                : 0
            let hasSentenceEnd = endsInTerminalPunctuation(word.text)

            if hasSentenceEnd || nextGap > longSilence {
                result.append(WordSpan(words: buffer))
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.isEmpty {
            result.append(WordSpan(words: buffer))
        }
        return result
    }

    private static func split(
        _ span: WordSpan,
        configuration: Configuration
    ) -> [WordSpan] {
        guard !fits(span, configuration: configuration), span.words.count > 1 else {
            return [span]
        }

        let words = span.words
        let count = words.count
        var costs = Array(repeating: Double.infinity, count: count + 1)
        var previous = Array(repeating: -1, count: count + 1)
        costs[0] = 0

        for end in 1...count {
            for start in stride(from: end - 1, through: 0, by: -1) {
                guard costs[start].isFinite else { continue }
                let candidate = WordSpan(words: Array(words[start..<end]))
                let isSingleUnavoidableWord = end - start == 1
                guard isSingleUnavoidableWord || fits(candidate, configuration: configuration) else {
                    continue
                }

                let totalCost = costs[start]
                    + cueCost(candidate, configuration: configuration)
                    + boundaryCost(words: words, boundary: end, longSilence: configuration.longSilence)

                if totalCost < costs[end] {
                    costs[end] = totalCost
                    previous[end] = start
                }
            }
        }

        guard previous[count] >= 0 else { return [span] }

        var result: [WordSpan] = []
        var cursor = count
        while cursor > 0 {
            let start = previous[cursor]
            guard start >= 0 else { return [span] }
            result.append(WordSpan(words: Array(words[start..<cursor])))
            cursor = start
        }
        return result.reversed()
    }

    private static func fits(
        _ span: WordSpan,
        configuration: Configuration
    ) -> Bool {
        let text = span.text
        let characterLimit = containsWideScript(text)
            ? configuration.maximumCJKCharacters
            : configuration.maximumLatinCharacters
        return visibleCharacterCount(text) <= max(1, characterLimit) &&
            span.duration <= max(0.08, configuration.targetMaximumDuration)
    }

    private static func cueCost(
        _ span: WordSpan,
        configuration: Configuration
    ) -> Double {
        let text = span.text
        let characterLimit = containsWideScript(text)
            ? configuration.maximumCJKCharacters
            : configuration.maximumLatinCharacters
        let characters = visibleCharacterCount(text)
        let characterFill = Double(characters) / Double(max(1, characterLimit))
        let durationFill = span.duration / max(0.08, configuration.targetMaximumDuration)
        let fill = max(characterFill, durationFill)

        // A base cost favors fewer cues. Under-fill and very-short penalties
        // prevent DP from leaving a one-character or blink-length remainder.
        var cost = 10.0 + pow(max(0, 0.62 - fill), 2) * 6.0
        if characters <= 1 {
            cost += 18
        } else if characters <= 3 {
            cost += 5
        }
        if span.duration < 0.7 {
            cost += 3
        }
        return cost
    }

    private static func boundaryCost(
        words: [SubtitleWordTiming],
        boundary: Int,
        longSilence: Double
    ) -> Double {
        guard boundary > 0, boundary < words.count else { return 0 }

        let left = words[boundary - 1]
        let right = words[boundary]
        let gap = right.startTime - left.endTime
        var cost = 0.0

        if endsInTerminalPunctuation(left.text) {
            cost -= 7
        } else if endsInMinorPunctuation(left.text) {
            cost -= 3.5
        }

        if gap >= longSilence {
            cost -= 8
        } else if gap >= 0.5 {
            cost -= 5
        } else if gap >= 0.2 {
            cost -= 2
        }

        if isProtectedTwoCharacterWord(left: left.text, right: right.text) {
            cost += 30
        }
        return cost
    }

    // MARK: - Isolated CJK character repair

    private static func repairIsolatedCJKCharacters(
        in input: [WordSpan],
        longSilence: Double
    ) -> [WordSpan] {
        guard input.count > 1 else { return input }

        var result = input
        var index = 0
        while index < result.count {
            guard isSingleHanCharacterCue(result[index].text) else {
                index += 1
                continue
            }

            let hasPrevious = index > 0
            let hasNext = index + 1 < result.count
            let gapBefore = hasPrevious
                ? result[index].startTime - result[index - 1].endTime
                : Double.infinity
            let gapAfter = hasNext
                ? result[index + 1].startTime - result[index].endTime
                : Double.infinity

            // A genuinely isolated utterance should remain a cue of its own.
            if gapBefore > longSilence && gapAfter > longSilence {
                index += 1
                continue
            }

            let previousHasSentenceEnd = hasPrevious &&
                endsInTerminalPunctuation(result[index - 1].text)

            if hasPrevious, !previousHasSentenceEnd, gapBefore <= longSilence {
                result[index - 1].words.append(contentsOf: result[index].words)
                result.remove(at: index)
            } else if hasNext, gapAfter <= longSilence {
                result[index + 1].words.insert(contentsOf: result[index].words, at: 0)
                result.remove(at: index)
            } else if hasPrevious, gapBefore <= longSilence {
                result[index - 1].words.append(contentsOf: result[index].words)
                result.remove(at: index)
            } else {
                index += 1
            }
        }
        return result
    }

    // MARK: - Text helpers

    private static let protectedTwoCharacterWords: Set<String> = [
        "相信", "遇见", "离开", "生命", "初心", "前程", "我们", "你们", "他们",
        "因为", "所以", "如果", "但是", "可以", "没有", "一个", "这个", "那个",
        "自己", "时候", "已经", "现在", "未来", "今天", "明天", "世界", "开始",
        "继续", "光影", "节目", "走进"
    ]

    private static func isProtectedTwoCharacterWord(left: String, right: String) -> Bool {
        guard let leftCharacter = left.reversed().first(where: isHanCharacter),
              let rightCharacter = right.first(where: isHanCharacter) else {
            return false
        }
        return protectedTwoCharacterWords.contains(String([leftCharacter, rightCharacter]))
    }

    private static func makeResultSegment(_ span: WordSpan) -> AIResultSegment? {
        guard let first = span.words.first, let last = span.words.last else { return nil }
        let text = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return AIResultSegment(
            text: text,
            startTime: first.startTime,
            endTime: max(last.endTime, first.startTime + 0.08)
        )
    }

    private static func joinedText(_ words: [String]) -> String {
        var result = ""
        for rawWord in words {
            let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }

            if let previous = result.last,
               let first = word.first,
               !previous.isWhitespace,
               !isPunctuationThatCloses(first),
               !isPunctuationThatOpens(previous),
               !isWideCharacter(previous),
               !isWideCharacter(first) {
                result.append(" ")
            }
            result.append(word)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func visibleCharacterCount(_ text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if !character.isWhitespace { count += 1 }
        }
    }

    private static func containsWideScript(_ text: String) -> Bool {
        text.contains(where: isWideCharacter)
    }

    private static func isSingleHanCharacterCue(_ text: String) -> Bool {
        var hanCount = 0
        for character in text {
            if isHanCharacter(character) {
                hanCount += 1
            } else if character.isLetter || character.isNumber {
                return false
            }
        }
        return hanCount == 1
    }

    private static func isHanCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }

    private static func isWideCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xAC00...0xD7AF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }

    private static func endsInTerminalPunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。！？!?；;".contains(last)
    }

    private static func endsInMinorPunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "，、,：:".contains(last)
    }

    private static func isPunctuationThatCloses(_ character: Character) -> Bool {
        ",.!?;:，。！？；：、)]}）】》〉」』”".contains(character)
    }

    private static func isPunctuationThatOpens(_ character: Character) -> Bool {
        "([{（【《〈「『“".contains(character)
    }
}
