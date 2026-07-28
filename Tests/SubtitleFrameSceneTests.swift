import CoreGraphics
import Foundation
@testable import Strophe

@main
struct SubtitleFrameSceneTests {
    static func main() {
        testAllOverlappingCuesAreActive()
        testEndTimeIsExclusive()
        testNormalCollisionKeepsLowerTrackAtBase()
        testReverseCollisionKeepsHigherTrackAtBase()
        testLayersDoNotCollideAndRenderBackToFront()
        testNormalizedAbsolutePositionSkipsCollision()
        testRotatedBitmapPreservesAuthoredAnchor()
        testSceneCursorReturnsEveryActiveCue()
        print("SubtitleFrameSceneTests: 8/8 passed")
    }

    private static let canvas = CGSize(width: 1920, height: 1080)
    private static let fixedMetrics = SubtitleBitmapMetrics(
        size: CGSize(width: 300, height: 60),
        anchorOffset: CGPoint(x: 150, y: 60)
    )

    private static func testAllOverlappingCuesAreActive() {
        let scene = resolve([
            cue(track: 0, start: 0, end: 3),
            cue(track: 1, start: 1, end: 2)
        ], time: 1.5)
        expect(scene.items.count == 2, "all overlapping cues must enter the frame scene")
    }

    private static func testEndTimeIsExclusive() {
        let first = cue(track: 0, start: 0, end: 2)
        let second = cue(track: 1, start: 2, end: 3)
        let scene = resolve([first, second], time: 2)
        expect(scene.items.map(\.id) == [second.id], "cue end time must be exclusive")
    }

    private static func testNormalCollisionKeepsLowerTrackAtBase() {
        let lowerTrack = cue(track: 0)
        let upperTrack = cue(track: 1)
        let scene = resolve([upperTrack, lowerTrack], mode: .normal)
        let lowerFrame = scene.items.first(where: { $0.id == lowerTrack.id })!.frame
        let upperFrame = scene.items.first(where: { $0.id == upperTrack.id })!.frame

        expect(approximately(lowerFrame.maxY, 1026), "normal collision should keep track 0 at the bottom margin")
        expect(upperFrame.maxY < lowerFrame.minY, "later tracks should wrap upward without overlap")
    }

    private static func testReverseCollisionKeepsHigherTrackAtBase() {
        let lowerTrack = cue(track: 0)
        let upperTrack = cue(track: 1)
        let scene = resolve([lowerTrack, upperTrack], mode: .reverse)
        let lowerFrame = scene.items.first(where: { $0.id == lowerTrack.id })!.frame
        let upperFrame = scene.items.first(where: { $0.id == upperTrack.id })!.frame

        expect(approximately(upperFrame.maxY, 1026), "reverse collision should keep the higher track at the bottom margin")
        expect(lowerFrame.maxY < upperFrame.minY, "earlier tracks should wrap upward in reverse mode")
    }

    private static func testLayersDoNotCollideAndRenderBackToFront() {
        let background = cue(track: 0, layer: 0)
        let foreground = cue(track: 0, layer: 2)
        let scene = resolve([foreground, background])

        expect(scene.items.map(\.id) == [background.id, foreground.id], "higher layers must render later")
        expect(scene.items[0].frame == scene.items[1].frame, "different layers should preserve intentional overlap")
    }

    private static func testNormalizedAbsolutePositionSkipsCollision() {
        var positioned = cue(track: 1)
        positioned.position = ResolvedSubtitlePosition(
            x: 0.25,
            y: 0.5,
            coordinateSpace: .normalized,
            anchor: .middleCenter
        )
        let base = cue(track: 0)
        let scene = SubtitleFrameSceneResolver.resolve(
            cues: [base, positioned],
            at: 1,
            canvasSize: canvas,
            collisionMode: .normal
        ) { cue in
            if cue.id == positioned.id {
                return SubtitleBitmapMetrics(
                    size: CGSize(width: 200, height: 50),
                    anchorOffset: CGPoint(x: 100, y: 25)
                )
            }
            return fixedMetrics
        }
        let item = scene.items.first(where: { $0.id == positioned.id })!

        expect(approximately(item.anchorPoint.x, 480), "normalized X should resolve against canvas width")
        expect(approximately(item.anchorPoint.y, 540), "normalized Y should resolve against canvas height")
        expect(item.origin == CGPoint(x: 380, y: 515), "absolute position should not be collision-shifted")
    }

    private static func testRotatedBitmapPreservesAuthoredAnchor() {
        var rotated = cue(track: 0)
        rotated.style.rotationDegrees = 37
        guard let metrics = SubtitleBitmapRenderer.metrics(cue: rotated, canvasSize: canvas) else {
            fail("rotated bitmap metrics should be available")
        }
        let scene = SubtitleFrameSceneResolver.resolve(
            cues: [rotated],
            at: 1,
            canvasSize: canvas,
            collisionMode: .normal
        ) { _ in metrics }
        let item = scene.items[0]
        let reconstructed = CGPoint(
            x: item.origin.x + metrics.anchorOffset.x,
            y: item.origin.y + metrics.anchorOffset.y
        )

        expect(approximately(reconstructed.x, 960), "rotation must preserve the horizontal anchor")
        expect(approximately(reconstructed.y, 1026), "rotation must preserve the vertical anchor")
    }

    private static func testSceneCursorReturnsEveryActiveCue() {
        let cues = [
            cue(track: 0, start: 0, end: 4),
            cue(track: 1, start: 1, end: 2),
            cue(track: 2, start: 1.5, end: 5)
        ].sorted { $0.startTime < $1.startTime }
        let cursor = SubtitleSceneCursor()

        expect(cursor.activeCues(at: 1.75, cues: cues).count == 3, "cursor must retain all overlaps")
        expect(cursor.activeCues(at: 2, cues: cues).count == 2, "cursor must remove cues at their exclusive end")
        expect(cursor.activeCues(at: 0.5, cues: cues).count == 1, "cursor must reset correctly after a backward seek")
    }

    private static func resolve(
        _ cues: [ResolvedSubtitleCue],
        time: Double = 1,
        mode: SubtitleCollisionMode = .normal
    ) -> SubtitleFrameScene {
        SubtitleFrameSceneResolver.resolve(
            cues: cues,
            at: time,
            canvasSize: canvas,
            collisionMode: mode
        ) { _ in fixedMetrics }
    }

    private static func cue(
        track: Int,
        layer: Int = 0,
        start: Double = 0,
        end: Double = 3
    ) -> ResolvedSubtitleCue {
        ResolvedSubtitleCue(
            id: UUID(),
            text: "字幕",
            startTime: start,
            endTime: end,
            style: .fallback,
            groupID: nil,
            trackIndex: track,
            layer: layer,
            position: nil
        )
    }

    private static func approximately(
        _ lhs: CGFloat,
        _ rhs: CGFloat,
        tolerance: CGFloat = 0.001
    ) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fatalError("SubtitleFrameSceneTests failed: \(message)")
    }
}
