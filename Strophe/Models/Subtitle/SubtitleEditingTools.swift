//
//  SubtitleEditingTools.swift
//  Strophe
//

import Foundation

nonisolated struct SubtitleSearchOptions: Equatable, Sendable {
    var isCaseSensitive = false
    var usesRegularExpression = false
    var matchesWholeWords = false
}

nonisolated enum SubtitleFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case timed
    case untimed
    case overlapping
    case hidden
    case selected

    var id: String { rawValue }
}

nonisolated struct SubtitleStatistics: Equatable, Sendable {
    var totalCount: Int
    var timedCount: Int
    var untimedCount: Int
    var characterCount: Int
    var wordCount: Int
    var totalTimelineDuration: TimeInterval
    var averageCueDuration: TimeInterval
    var averageCharactersPerSecond: Double
    var maximumCharactersPerSecond: Double
    var gapCount: Int
    var overlapCount: Int
}

nonisolated enum SubtitleOverlapRepairMode: String, CaseIterable, Identifiable, Sendable {
    case trimEarlier
    case shiftLater

    var id: String { rawValue }
}

nonisolated enum SubtitleEditingTools {
    static func matches(
        _ text: String,
        query: String,
        options: SubtitleSearchOptions
    ) -> Bool {
        guard !query.isEmpty else { return true }
        if options.usesRegularExpression {
            return regularExpression(query, options: options)?
                .firstMatch(
                    in: text,
                    range: NSRange(text.startIndex..<text.endIndex, in: text)
                ) != nil
        }

        var stringOptions: String.CompareOptions = []
        if !options.isCaseSensitive { stringOptions.insert(.caseInsensitive) }
        guard options.matchesWholeWords else {
            return text.range(of: query, options: stringOptions) != nil
        }

        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(
                of: query,
                options: stringOptions,
                range: searchStart..<text.endIndex
              ) {
            if isWordBoundary(range.lowerBound, in: text),
               isWordBoundary(range.upperBound, in: text) {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    static func replacing(
        _ text: String,
        query: String,
        replacement: String,
        options: SubtitleSearchOptions
    ) -> String {
        guard !query.isEmpty else { return text }
        if options.usesRegularExpression {
            guard let regex = regularExpression(query, options: options) else { return text }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.stringByReplacingMatches(
                in: text,
                range: range,
                withTemplate: replacement
            )
        }

        var compareOptions: String.CompareOptions = []
        if !options.isCaseSensitive { compareOptions.insert(.caseInsensitive) }
        if !options.matchesWholeWords {
            return text.replacingOccurrences(
                of: query,
                with: replacement,
                options: compareOptions
            )
        }

        var result = text
        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let range = result.range(
                of: query,
                options: compareOptions,
                range: searchStart..<result.endIndex
              ) {
            if isWordBoundary(range.lowerBound, in: result),
               isWordBoundary(range.upperBound, in: result) {
                result.replaceSubrange(range, with: replacement)
                searchStart = result.index(
                    range.lowerBound,
                    offsetBy: replacement.count,
                    limitedBy: result.endIndex
                ) ?? result.endIndex
            } else {
                searchStart = range.upperBound
            }
        }
        return result
    }

    static func statistics(for items: [SubtitleItem]) -> SubtitleStatistics {
        let timed = items.compactMap { item -> (SubtitleItem, Double, Double)? in
            guard let start = item.startTime, let end = item.endTime, end >= start else {
                return nil
            }
            return (item, start, end)
        }
        let durations = timed.map { $0.2 - $0.1 }
        let cps = timed.compactMap { item, start, end -> Double? in
            let duration = end - start
            guard duration > 0 else { return nil }
            return Double(item.text.filter { !$0.isWhitespace }.count) / duration
        }
        let sorted = timed.sorted { $0.1 < $1.1 }
        var gapCount = 0
        var overlapCount = 0
        if sorted.count > 1 {
            for index in 1..<sorted.count {
                let delta = sorted[index].1 - sorted[index - 1].2
                if delta > 0.001 { gapCount += 1 }
                if delta < -0.001 { overlapCount += 1 }
            }
        }

        let wordCount = items.reduce(into: 0) { count, item in
            count += item.text.split(whereSeparator: \.isWhitespace).count
        }
        let characterCount = items.reduce(into: 0) { count, item in
            count += item.text.filter { !$0.isWhitespace }.count
        }
        let totalDuration = durations.reduce(0, +)
        return SubtitleStatistics(
            totalCount: items.count,
            timedCount: timed.count,
            untimedCount: items.count - timed.count,
            characterCount: characterCount,
            wordCount: wordCount,
            totalTimelineDuration: totalDuration,
            averageCueDuration: durations.isEmpty ? 0 : totalDuration / Double(durations.count),
            averageCharactersPerSecond: cps.isEmpty ? 0 : cps.reduce(0, +) / Double(cps.count),
            maximumCharactersPerSecond: cps.max() ?? 0,
            gapCount: gapCount,
            overlapCount: overlapCount
        )
    }

    private static func regularExpression(
        _ query: String,
        options: SubtitleSearchOptions
    ) -> NSRegularExpression? {
        let pattern = options.matchesWholeWords ? "\\b(?:\(query))\\b" : query
        let regexOptions: NSRegularExpression.Options = options.isCaseSensitive
            ? []
            : [.caseInsensitive]
        return try? NSRegularExpression(pattern: pattern, options: regexOptions)
    }

    private static func isWordBoundary(_ index: String.Index, in text: String) -> Bool {
        let beforeIsWord: Bool
        if index > text.startIndex {
            beforeIsWord = text[text.index(before: index)].isLetter
                || text[text.index(before: index)].isNumber
                || text[text.index(before: index)] == "_"
        } else {
            beforeIsWord = false
        }
        let afterIsWord: Bool
        if index < text.endIndex {
            afterIsWord = text[index].isLetter || text[index].isNumber || text[index] == "_"
        } else {
            afterIsWord = false
        }
        return beforeIsWord != afterIsWord || (!beforeIsWord && !afterIsWord)
    }
}
