import Foundation

@main
struct SubtitleSegmentationTests {
    static func main() {
        testContinuityClosesShortGap()
        testContinuityRemovesSmallOverlap()
        testContinuityPreservesLongPause()
        testContinuityCanBeDisabled()
        testContinuityIncludesExactThreshold()
        testContinuityRejectsInvalidEnd()
        testContinuityPreservesTextAndStarts()
        testCJKDynamicProgrammingLimits()
        testLatinDynamicProgrammingLimits()
        testDurationLimit()
        testPunctuationRestoresSentences()
        testTerminalBeforeSingleCharacterMergesForward()
        testLongSilencePreservesSingleCharacter()
        testProtectedWordIsNotSplitWhenAnotherBoundaryFits()
        testConfiguredThreshold()
        testSRTRoundsMillisecondsAndCarriesSeconds()
        print("SubtitleSegmentationTests: 16/16 passed")
    }

    private static func testContinuityClosesShortGap() {
        let result = SubtitleSegmentation.smoothTimeline([
            segment("一", 0, 1),
            segment("二", 1.6, 2)
        ], threshold: 1)
        expect(result[0].endTime == 1.6, "short gap should extend the previous cue")
    }

    private static func testContinuityRemovesSmallOverlap() {
        let result = SubtitleSegmentation.smoothTimeline([
            segment("一", 0, 2),
            segment("二", 1.75, 3)
        ], threshold: 1)
        expect(result[0].endTime == 1.75, "small overlap should shorten the previous cue")
    }

    private static func testContinuityPreservesLongPause() {
        let input = [segment("一", 0, 1), segment("二", 2.1, 3)]
        let result = SubtitleSegmentation.smoothTimeline(input, threshold: 1)
        expect(result[0].endTime == input[0].endTime, "a pause over the threshold should remain unchanged")
    }

    private static func testContinuityCanBeDisabled() {
        let input = [segment("一", 0, 1), segment("二", 1.2, 2)]
        let result = SubtitleSegmentation.smoothTimeline(input, threshold: 0)
        expect(result[0].endTime == input[0].endTime, "zero should disable timeline smoothing")
    }

    private static func testContinuityIncludesExactThreshold() {
        let result = SubtitleSegmentation.smoothTimeline([
            segment("一", 0, 1),
            segment("二", 2, 3)
        ], threshold: 1)
        expect(result[0].endTime == 2, "the configured threshold should be inclusive")
    }

    private static func testContinuityRejectsInvalidEnd() {
        let result = SubtitleSegmentation.smoothTimeline([
            segment("一", 2, 2.3),
            segment("二", 1.8, 3)
        ], threshold: 1)
        expect(result[0].endTime == 2.3, "smoothing must not end a cue before it starts")
    }

    private static func testContinuityPreservesTextAndStarts() {
        let result = SubtitleSegmentation.smoothTimeline([
            segment("原文", 0.25, 1),
            segment("下一句", 1.4, 2)
        ], threshold: 1)
        expect(result[0].text == "原文", "smoothing should preserve recognized text")
        expect(result[0].startTime == 0.25, "smoothing should preserve cue starts")
    }

    private static func testCJKDynamicProgrammingLimits() {
        let characters = Array("光影映初心笃行赴前程本期节目我们走进了新的世界")
        let words = characters.enumerated().map { index, character in
            SubtitleWordTiming(
                text: String(character),
                startTime: Double(index) * 0.32,
                endTime: Double(index) * 0.32 + 0.25
            )
        }
        let result = SubtitleSegmentation.makeSegments(words: words)
        expect(result.count >= 2, "overlong CJK text should be split")
        expect(result.allSatisfy { $0.text.count <= 17 }, "CJK cues should stay within 17 characters")
        expect(result.allSatisfy { $0.endTime - $0.startTime <= 6.2 }, "cues should stay within 6.2 seconds")
    }

    private static func testLatinDynamicProgrammingLimits() {
        let words = (0..<30).map { index in
            SubtitleWordTiming(
                text: "word",
                startTime: Double(index) * 0.2,
                endTime: Double(index) * 0.2 + 0.15
            )
        }
        let result = SubtitleSegmentation.makeSegments(words: words)
        expect(result.count >= 2, "overlong Latin text should be split")
        expect(result.allSatisfy { $0.text.count <= 84 }, "Latin cues should stay within 84 characters")
    }

    private static func testDurationLimit() {
        let words = (0..<12).map { index in
            SubtitleWordTiming(
                text: "词",
                startTime: Double(index) * 0.7,
                endTime: Double(index) * 0.7 + 0.2
            )
        }
        let result = SubtitleSegmentation.makeSegments(words: words)
        expect(result.count >= 2, "a long-duration sentence should be split")
        expect(result.allSatisfy { $0.endTime - $0.startTime <= 6.2 }, "the duration target should cap splittable cues")
    }

    private static func testPunctuationRestoresSentences() {
        let words = [
            SubtitleWordTiming(text: "你好。", startTime: 0, endTime: 1),
            SubtitleWordTiming(text: "世界。", startTime: 1.1, endTime: 2)
        ]
        let result = SubtitleSegmentation.makeSegments(words: words)
        expect(result.map(\.text) == ["你好。", "世界。"], "terminal punctuation should restore sentence cues")
    }

    private static func testTerminalBeforeSingleCharacterMergesForward() {
        let words = [
            SubtitleWordTiming(text: "准备。", startTime: 0, endTime: 1),
            SubtitleWordTiming(text: "好。", startTime: 1.2, endTime: 1.5),
            SubtitleWordTiming(text: "我们继续。", startTime: 1.7, endTime: 2.8)
        ]
        let result = SubtitleSegmentation.makeSegments(words: words)
        expect(result.count == 2, "an isolated character should merge with a neighbor")
        expect(result[1].text == "好。我们继续。", "a terminal previous cue should make the character merge forward")
        expect(result[1].startTime == 1.2, "forward merge should retain the isolated character start")
    }

    private static func testLongSilencePreservesSingleCharacter() {
        let words = [
            SubtitleWordTiming(text: "准备。", startTime: 0, endTime: 1),
            SubtitleWordTiming(text: "好。", startTime: 2.2, endTime: 2.5),
            SubtitleWordTiming(text: "继续。", startTime: 3.8, endTime: 5)
        ]
        let result = SubtitleSegmentation.makeSegments(words: words)
        expect(result.map(\.text) == ["准备。", "好。", "继续。"], "long silence on both sides should preserve a single-character utterance")
    }

    private static func testProtectedWordIsNotSplitWhenAnotherBoundaryFits() {
        let characters = Array("春天我相信未来")
        let words = characters.enumerated().map { index, character in
            SubtitleWordTiming(
                text: String(character),
                startTime: Double(index) * 0.4,
                endTime: Double(index) * 0.4 + 0.3
            )
        }
        var configuration = SubtitleSegmentation.Configuration()
        configuration.maximumCJKCharacters = 4
        let result = SubtitleSegmentation.makeSegments(words: words, configuration: configuration)
        expect(result.allSatisfy { !$0.text.hasSuffix("相") }, "a valid alternative should avoid splitting 相信")
        expect(result.contains { $0.text.contains("相信") }, "protected two-character words should stay together")
    }

    private static func testConfiguredThreshold() {
        let key = SubtitleSegmentation.continuityEnvironmentKey
        let previousValue = ProcessInfo.processInfo.environment[key]
        setenv(key, "0.35", 1)
        expect(SubtitleSegmentation.configuredContinuityThreshold == 0.35, "the environment should configure continuity")
        if let previousValue {
            setenv(key, previousValue, 1)
        } else {
            unsetenv(key)
        }
    }

    private static func testSRTRoundsMillisecondsAndCarriesSeconds() {
        let timestamp = SubtitleTimeFormatter.format(seconds: 59.9996, format: .srt)
        expect(timestamp == "00:01:00,000", "SRT output should round milliseconds and carry into the next second")
    }

    private static func segment(_ text: String, _ start: Double, _ end: Double) -> AIResultSegment {
        AIResultSegment(text: text, startTime: start, endTime: end)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
