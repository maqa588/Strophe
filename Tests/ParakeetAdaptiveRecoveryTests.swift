import Foundation

@main
struct ParakeetAdaptiveRecoveryTests {
    static func main() {
        testFindsCompletelyMissingSpeechIsland()
        testFindsInternalAndTrailingGaps()
        testIgnoresShortNaturalTokenGap()
        testContextualWindowAddsFourSeconds()
        testShiftedWindowMovesGapNearBeginning()
        testLongGapUsesMultipleFixedWindows()
        print("ParakeetAdaptiveRecoveryTests: 6/6 passed")
    }

    private static func testFindsCompletelyMissingSpeechIsland() {
        let result = ParakeetAdaptiveRecovery.missingSpeechRanges(
            speechRanges: [.init(start: 9, end: 12)],
            tokenRanges: [],
            minimumDuration: 1
        )
        expect(result == [.init(start: 9, end: 12)], "a token-free speech island should be retried")
    }

    private static func testFindsInternalAndTrailingGaps() {
        let result = ParakeetAdaptiveRecovery.missingSpeechRanges(
            speechRanges: [.init(start: 40, end: 53)],
            tokenRanges: [
                .init(start: 40, end: 41),
                .init(start: 49, end: 50),
            ],
            minimumDuration: 1
        )
        expect(
            result == [
                .init(start: 41, end: 49),
                .init(start: 50, end: 53),
            ],
            "missing portions inside a longer VAD island should be found"
        )
    }

    private static func testIgnoresShortNaturalTokenGap() {
        let result = ParakeetAdaptiveRecovery.missingSpeechRanges(
            speechRanges: [.init(start: 0, end: 2)],
            tokenRanges: [
                .init(start: 0, end: 0.6),
                .init(start: 1.2, end: 2),
            ],
            minimumDuration: 1
        )
        expect(result.isEmpty, "a sub-second pause should not trigger another inference")
    }

    private static func testContextualWindowAddsFourSeconds() {
        let result = ParakeetAdaptiveRecovery.contextualWindow(
            for: .init(start: 8, end: 12),
            audioDuration: 30
        )
        expect(result.audio == .init(start: 4, end: 16), "the first retry should include four seconds on both sides")
        expect(result.acceptance == .init(start: 8, end: 12), "only the missing interval should accept tokens")
    }

    private static func testShiftedWindowMovesGapNearBeginning() {
        let result = ParakeetAdaptiveRecovery.shiftedWindows(
            for: .init(start: 40, end: 49),
            audioDuration: 100
        )
        expect(result.count == 1, "a nine-second gap should fit one retry")
        expect(result[0].audio == .init(start: 40, end: 55), "the fallback should use a shifted 15-second window")
        expect(result[0].acceptance == .init(start: 40, end: 49), "fallback tokens should stay inside the gap")
    }

    private static func testLongGapUsesMultipleFixedWindows() {
        let result = ParakeetAdaptiveRecovery.shiftedWindows(
            for: .init(start: 20, end: 42),
            audioDuration: 60
        )
        expect(result.count == 2, "a long missed region should be covered by multiple model windows")
        expect(result.allSatisfy { $0.audio.duration <= 15 }, "no fallback window may exceed the Core ML input")
        expect(result.first?.acceptance.start == 20, "coverage should start at the missed region")
        expect(result.last?.acceptance.end == 42, "coverage should reach the end of the missed region")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
