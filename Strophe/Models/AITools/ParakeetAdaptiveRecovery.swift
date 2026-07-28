//
//  ParakeetAdaptiveRecovery.swift
//  Strophe
//

import Foundation

/// Pure timeline helpers for Parakeet-JA's adaptive second recognition pass.
///
/// FireRedVAD supplies speech ranges and Parakeet supplies timestamped tokens.
/// Any sufficiently long part of a speech range without a token is retried with
/// additional context and, when necessary, a deliberately shifted 15-second
/// model window.
nonisolated enum ParakeetAdaptiveRecovery {
    struct TimeRange: Sendable, Equatable {
        let start: Double
        let end: Double

        var duration: Double { max(0, end - start) }
    }

    struct RetryWindow: Sendable, Equatable {
        /// Audio passed to Parakeet.
        let audio: TimeRange
        /// Only tokens whose centers fall here are accepted.
        let acceptance: TimeRange
    }

    struct Configuration: Sendable {
        var minimumMissingDuration = 1.0
        var contextDuration = 4.0
        var shiftedLeadingContext = 0.0
        var maximumModelWindow = 15.0
    }

    /// Finds token-free portions of VAD speech ranges.
    static func missingSpeechRanges(
        speechRanges: [TimeRange],
        tokenRanges: [TimeRange],
        minimumDuration: Double
    ) -> [TimeRange] {
        let minimumDuration = max(0, minimumDuration)
        let validTokens = tokenRanges
            .filter { $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }
            .sorted {
                $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
            }
        var result: [TimeRange] = []

        for speech in speechRanges
        where speech.start.isFinite && speech.end.isFinite && speech.end > speech.start {
            var cursor = speech.start
            for token in validTokens where token.end > speech.start && token.start < speech.end {
                let tokenStart = max(speech.start, token.start)
                if tokenStart - cursor >= minimumDuration {
                    result.append(TimeRange(start: cursor, end: tokenStart))
                }
                cursor = max(cursor, min(speech.end, token.end))
                if cursor >= speech.end { break }
            }
            if speech.end - cursor >= minimumDuration {
                result.append(TimeRange(start: cursor, end: speech.end))
            }
        }
        return result
    }

    /// First retry: preserve 3–5 seconds of context on both sides.
    static func contextualWindow(
        for missing: TimeRange,
        audioDuration: Double,
        configuration: Configuration = Configuration()
    ) -> RetryWindow {
        let duration = max(0, audioDuration)
        return RetryWindow(
            audio: TimeRange(
                start: max(0, missing.start - configuration.contextDuration),
                end: min(duration, missing.end + configuration.contextDuration)
            ),
            acceptance: missing
        )
    }

    /// Fallback retry: place the missed speech close to the beginning of a
    /// fixed 15-second encoder window. This changes the acoustic context when
    /// the ordinary context-expanded pass still emits no tokens.
    static func shiftedWindows(
        for missing: TimeRange,
        audioDuration: Double,
        configuration: Configuration = Configuration()
    ) -> [RetryWindow] {
        let duration = max(0, audioDuration)
        guard missing.end > missing.start, duration > 0 else { return [] }

        let leading = max(0, configuration.shiftedLeadingContext)
        let trailing = max(0, configuration.contextDuration)
        let maximumWindow = max(1, configuration.maximumModelWindow)
        let targetDuration = max(1, maximumWindow - leading - trailing)
        var result: [RetryWindow] = []
        var targetStart = max(0, missing.start)
        let targetEnd = min(duration, missing.end)

        while targetStart < targetEnd {
            let sliceEnd = min(targetEnd, targetStart + targetDuration)
            var audioStart = max(0, targetStart - leading)
            var audioEnd = min(duration, max(sliceEnd + trailing, audioStart + maximumWindow))
            if audioEnd - audioStart > maximumWindow {
                audioEnd = audioStart + maximumWindow
            }
            if audioEnd < sliceEnd {
                audioEnd = sliceEnd
                audioStart = max(0, audioEnd - maximumWindow)
            }
            result.append(
                RetryWindow(
                    audio: TimeRange(start: audioStart, end: audioEnd),
                    acceptance: TimeRange(start: targetStart, end: sliceEnd)
                )
            )
            targetStart = sliceEnd
        }
        return result
    }
}
