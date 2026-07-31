import CoreGraphics
import XCTest
@testable import Strophe

final class KaraokeRenderingTests: XCTestCase {
    func testStateEvaluatorUsesExactUnitBoundaries() throws {
        let program = try XCTUnwrap(
            KaraokeProgram.evenlyTimed(text: "AB", duration: 2)
        )

        let before = KaraokeFrameStateEvaluator.states(
            program: program,
            cueLocalTime: -0.01
        )
        XCTAssertEqual(before.map(\.phase), [.upcoming, .upcoming])

        let firstMiddle = KaraokeFrameStateEvaluator.states(
            program: program,
            cueLocalTime: 0.5
        )
        XCTAssertEqual(firstMiddle.map(\.phase), [.active, .upcoming])
        XCTAssertEqual(firstMiddle[0].progress, 0.5, accuracy: 0.000_001)

        let sharedBoundary = KaraokeFrameStateEvaluator.states(
            program: program,
            cueLocalTime: 1
        )
        XCTAssertEqual(sharedBoundary.map(\.phase), [.completed, .active])
        XCTAssertEqual(sharedBoundary[1].progress, 0, accuracy: 0.000_001)
    }

    func testCoreTextBuildsOneFillLayerPerTimingUnit() throws {
        let cue = try makeCue(template: .classicSweep)
        let asset = try XCTUnwrap(
            SubtitleBitmapRenderer.makeKaraokeAsset(
                cue: cue,
                canvasSize: CGSize(width: 1920, height: 1080)
            )
        )

        XCTAssertEqual(asset.unitLayers.count, cue.karaoke?.units.count)
        XCTAssertTrue(asset.unitLayers.allSatisfy { $0.image.width > 0 })
        XCTAssertTrue(asset.unitLayers.allSatisfy { $0.image.height > 0 })
    }

    func testRendererRepairsLegacyZeroDurationUnitsInsteadOfLeavingGrayGlyphs() throws {
        var cue = try makeCue(template: .classicSweep)
        var program = try XCTUnwrap(cue.karaoke)
        program.units[0].endOffset = program.units[0].startOffset
        program.units[1].startOffset = program.units[0].startOffset - 0.1
        cue.karaoke = program

        let asset = try XCTUnwrap(
            SubtitleBitmapRenderer.makeKaraokeAsset(
                cue: cue,
                canvasSize: CGSize(width: 1920, height: 1080)
            )
        )

        XCTAssertEqual(asset.unitLayers.count, program.units.count)
        XCTAssertTrue(
            asset.unitLayers.allSatisfy {
                $0.unit.endOffset > $0.unit.startOffset
            })
    }

    func testManyFramesReuseOneRasterizedAsset() throws {
        let renderer = KaraokeFrameRenderer(device: nil)
        let cue = try makeCue(template: .classicSweep)
        let canvas = CGSize(width: 1280, height: 720)
        let initialStats = renderer.cacheStatistics()

        for frame in 0..<90 {
            let time = cue.startTime + Double(frame) / 60
            XCTAssertNotNil(
                renderer.makeCGImage(
                    cue: cue,
                    presentationTime: time,
                    canvasSize: canvas
                )
            )
        }

        let stats = renderer.cacheStatistics()
        XCTAssertEqual(stats.assetCount - initialStats.assetCount, 1)
        XCTAssertEqual(stats.assetBuildCount - initialStats.assetBuildCount, 1)
    }

    func testTimingAndFrameOnlyTemplateChangesReuseRasterizedAsset() throws {
        let renderer = KaraokeFrameRenderer(device: nil)
        let canvas = CGSize(width: 1280, height: 720)
        let cue = try makeCue(template: .glow)

        XCTAssertNotNil(renderer.metrics(cue: cue, canvasSize: canvas))
        XCTAssertEqual(renderer.cacheStatistics().assetBuildCount, 1)

        var dynamicCue = cue
        var program = try XCTUnwrap(dynamicCue.karaoke)
        program.units[0].endOffset -= 0.08
        program.units[1].startOffset -= 0.08
        program.template.revealMode = .step
        program.template.glowIntensity = 0.35
        dynamicCue.karaoke = program

        XCTAssertNotNil(renderer.metrics(cue: dynamicCue, canvasSize: canvas))
        XCTAssertEqual(renderer.cacheStatistics().assetBuildCount, 1)

        program.template.activeColorHex = "#FF4D8DFF"
        dynamicCue.karaoke = program
        XCTAssertNotNil(renderer.metrics(cue: dynamicCue, canvasSize: canvas))
        XCTAssertEqual(renderer.cacheStatistics().assetBuildCount, 2)
    }

    func testCachedAssetEvaluatesLatestKaraokeTimingAfterCueStretch() throws {
        let renderer = KaraokeFrameRenderer(device: nil)
        let canvas = CGSize(width: 1280, height: 720)
        let cue = try makeCue(template: .classicStep)
        let presentationTime = cue.startTime + 0.6
        let originalFrame = try XCTUnwrap(
            renderer.makeCGImage(
                cue: cue,
                presentationTime: presentationTime,
                canvasSize: canvas
            )
        )
        XCTAssertEqual(renderer.cacheStatistics().assetBuildCount, 1)

        var stretchedCue = cue
        stretchedCue.endTime = cue.startTime + 3
        stretchedCue.karaoke = cue.karaoke?.scalingOffsets(by: 1.5)
        let stretchedFrame = try XCTUnwrap(
            renderer.makeCGImage(
                cue: stretchedCue,
                presentationTime: presentationTime,
                canvasSize: canvas
            )
        )

        XCTAssertEqual(renderer.cacheStatistics().assetBuildCount, 1)
        XCTAssertNotEqual(
            pixelData(originalFrame),
            pixelData(stretchedFrame)
        )
    }

    func testSweepChangesPixelsWhileKeepingStableMaximumBounds() throws {
        let renderer = KaraokeFrameRenderer(device: nil)
        let cue = try makeCue(template: .glow)
        let canvas = CGSize(width: 1280, height: 720)
        let metrics = try XCTUnwrap(
            renderer.metrics(cue: cue, canvasSize: canvas)
        )
        let frames = try [
            cue.startTime,
            cue.startTime + 0.25,
            cue.startTime + 0.75,
            cue.startTime + 1.75,
        ].map { time in
            try XCTUnwrap(
                renderer.makeCGImage(
                    cue: cue,
                    presentationTime: time,
                    canvasSize: canvas
                )
            )
        }

        for image in frames {
            XCTAssertEqual(CGFloat(image.width), metrics.size.width)
            XCTAssertEqual(CGFloat(image.height), metrics.size.height)
        }
        XCTAssertNotEqual(pixelData(frames[0]), pixelData(frames[1]))
        XCTAssertNotEqual(pixelData(frames[1]), pixelData(frames[2]))
    }

    func testStepAndSweepProduceDifferentActiveFrames() throws {
        let renderer = KaraokeFrameRenderer(device: nil)
        let stepCue = try makeCue(template: .classicStep)
        let sweepCue = try makeCue(template: .classicSweep)
        let canvas = CGSize(width: 960, height: 540)
        let time = stepCue.startTime + 0.2
        let step = try XCTUnwrap(
            renderer.makeCGImage(
                cue: stepCue,
                presentationTime: time,
                canvasSize: canvas
            )
        )
        let sweep = try XCTUnwrap(
            renderer.makeCGImage(
                cue: sweepCue,
                presentationTime: time,
                canvasSize: canvas
            )
        )

        XCTAssertEqual(step.width, sweep.width)
        XCTAssertEqual(step.height, sweep.height)
        XCTAssertNotEqual(pixelData(step), pixelData(sweep))
    }

    func testEffectPaddingUsesActualShapedUnitAndAddsPopToGlow() throws {
        let text = "extraordinarilylongword"
        var template = KaraokeTemplateConfiguration.glow
        template.popScale = 1.35
        template.glowRadius = 12
        let unit = KaraokeTimingUnit(
            text: text,
            characterStart: 0,
            characterLength: Array(text).count,
            startOffset: 0,
            endOffset: 2,
            source: .manual
        )
        let program = KaraokeProgram(
            textSnapshot: text,
            units: [unit],
            template: template
        )
        var style = ResolvedSubtitleStyle.fallback
        style.fontSize = 72
        let cue = ResolvedSubtitleCue(
            id: UUID(),
            text: text,
            startTime: 0,
            endTime: 2,
            style: style,
            groupID: nil,
            trackIndex: 0,
            layer: 0,
            position: nil,
            karaoke: program
        )
        let asset = try XCTUnwrap(
            SubtitleBitmapRenderer.makeKaraokeAsset(
                cue: cue,
                canvasSize: CGSize(width: 1920, height: 1080)
            )
        )
        let layer = try XCTUnwrap(asset.unitLayers.first)
        let expected = template.maximumOutset(
            maxUnitWidth: Double(layer.image.width),
            maxUnitHeight: Double(layer.image.height)
        )

        XCTAssertEqual(asset.baseOrigin.x, expected, accuracy: 0.000_001)
        XCTAssertEqual(asset.baseOrigin.y, expected, accuracy: 0.000_001)
        XCTAssertGreaterThan(expected, template.glowRadius * 3)
    }

    func testEffectPaddingKeepsVisualTextAnchorFixed() throws {
        var cue = try makeCue(template: .glow)
        cue.style.rotationDegrees = 23
        let asset = try XCTUnwrap(
            SubtitleBitmapRenderer.makeKaraokeAsset(
                cue: cue,
                canvasSize: CGSize(width: 1920, height: 1080)
            )
        )

        // The padded effect canvas must rotate around the original text
        // anchor, not around the outer transparent edge.
        let visualAnchorInSource = CGPoint(
            x: asset.baseOrigin.x + CGFloat(asset.baseImage.width) / 2,
            y: asset.baseOrigin.y
        )
        let transformedVisualAnchor = visualAnchorInSource.applying(
            asset.sourceToOutputTransform
        )
        let metricsAnchorInCoreImageCoordinates = CGPoint(
            x: asset.metrics.anchorOffset.x,
            y: asset.metrics.size.height - asset.metrics.anchorOffset.y
        )

        XCTAssertEqual(
            transformedVisualAnchor.x,
            metricsAnchorInCoreImageCoordinates.x,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            transformedVisualAnchor.y,
            metricsAnchorInCoreImageCoordinates.y,
            accuracy: 0.000_001
        )
    }

    func testAssetCacheEvictsLeastRecentlyUsedEntryAtFixedCapacity() throws {
        let renderer = KaraokeFrameRenderer(device: nil)
        let canvas = CGSize(width: 640, height: 360)
        var cues: [ResolvedSubtitleCue] = []

        for index in 0..<33 {
            let text = "K\(index)"
            let program = try XCTUnwrap(
                KaraokeProgram.evenlyTimed(text: text, duration: 1)
            )
            cues.append(
                ResolvedSubtitleCue(
                    id: UUID(),
                    text: text,
                    startTime: 0,
                    endTime: 1,
                    style: .fallback,
                    groupID: nil,
                    trackIndex: 0,
                    layer: 0,
                    position: nil,
                    karaoke: program
                )
            )
        }

        for cue in cues.prefix(32) {
            XCTAssertNotNil(renderer.metrics(cue: cue, canvasSize: canvas))
        }
        XCTAssertEqual(renderer.cacheStatistics().assetCount, 32)

        // Keep entry zero hot; entry one is now the least recently used.
        XCTAssertNotNil(renderer.metrics(cue: cues[0], canvasSize: canvas))
        XCTAssertNotNil(renderer.metrics(cue: cues[32], canvasSize: canvas))
        XCTAssertEqual(renderer.cacheStatistics().assetBuildCount, 33)
        XCTAssertNotNil(renderer.metrics(cue: cues[0], canvasSize: canvas))
        XCTAssertEqual(renderer.cacheStatistics().assetBuildCount, 33)
        XCTAssertNotNil(renderer.metrics(cue: cues[1], canvasSize: canvas))
        XCTAssertEqual(renderer.cacheStatistics().assetBuildCount, 34)
        XCTAssertEqual(renderer.cacheStatistics().assetCount, 32)
    }

    func testAbsoluteAnchorStaysFixedAcrossRotationAndKaraokeProgress() throws {
        var cue = try makeCue(template: .pop)
        cue.style.rotationDegrees = 27
        cue.position = ResolvedSubtitlePosition(
            x: 500,
            y: 300,
            coordinateSpace: .canvas,
            anchor: .bottomCenter
        )
        let canvas = CGSize(width: 1280, height: 720)
        let renderer = KaraokeFrameRenderer(device: nil)

        let sceneA = SubtitleFrameSceneResolver.resolve(
            cues: [cue],
            at: cue.startTime + 0.05,
            canvasSize: canvas,
            collisionMode: .normal
        ) { renderer.metrics(cue: $0, canvasSize: canvas) }
        let sceneB = SubtitleFrameSceneResolver.resolve(
            cues: [cue],
            at: cue.startTime + 1.2,
            canvasSize: canvas,
            collisionMode: .normal
        ) { renderer.metrics(cue: $0, canvasSize: canvas) }

        let itemA = try XCTUnwrap(sceneA.items.first)
        let itemB = try XCTUnwrap(sceneB.items.first)
        XCTAssertEqual(itemA.anchorPoint.x, 500, accuracy: 0.000_001)
        XCTAssertEqual(itemA.anchorPoint.y, 300, accuracy: 0.000_001)
        XCTAssertEqual(itemA.anchorPoint, itemB.anchorPoint)
        XCTAssertEqual(itemA.frame, itemB.frame)
    }

    func testSceneResolvesAllCuesInLayerTrackOrderWithNormalAndReverseCollision() {
        let canvas = CGSize(width: 640, height: 360)
        let metrics = SubtitleBitmapMetrics(
            size: CGSize(width: 120, height: 40),
            anchorOffset: CGPoint(x: 60, y: 40)
        )
        let trackZero = sceneCue(track: 0, layer: 0)
        let trackOne = sceneCue(track: 1, layer: 0)
        let upperLayer = sceneCue(track: 2, layer: 1)
        let absolute = sceneCue(
            track: 3,
            layer: 2,
            position: ResolvedSubtitlePosition(
                x: 96,
                y: 88,
                coordinateSpace: .canvas,
                anchor: .bottomCenter
            )
        )
        let unsortedCues = [absolute, upperLayer, trackOne, trackZero]

        let normal = SubtitleFrameSceneResolver.resolve(
            cues: unsortedCues,
            at: 1,
            canvasSize: canvas,
            collisionMode: .normal
        ) { _ in metrics }
        let reverse = SubtitleFrameSceneResolver.resolve(
            cues: unsortedCues,
            at: 1,
            canvasSize: canvas,
            collisionMode: .reverse
        ) { _ in metrics }

        XCTAssertEqual(
            normal.items.map { "\($0.cue.layer):\($0.cue.trackIndex)" },
            ["0:0", "0:1", "1:2", "2:3"]
        )
        XCTAssertEqual(normal.items.count, 4)

        let normalByID = Dictionary(uniqueKeysWithValues: normal.items.map { ($0.id, $0) })
        let reverseByID = Dictionary(uniqueKeysWithValues: reverse.items.map { ($0.id, $0) })
        XCTAssertGreaterThan(
            normalByID[trackZero.id]?.anchorPoint.y ?? 0,
            normalByID[trackOne.id]?.anchorPoint.y ?? 0
        )
        XCTAssertGreaterThan(
            reverseByID[trackOne.id]?.anchorPoint.y ?? 0,
            reverseByID[trackZero.id]?.anchorPoint.y ?? 0
        )
        XCTAssertEqual(normalByID[upperLayer.id]?.anchorPoint.y, 342)
        XCTAssertEqual(normalByID[absolute.id]?.anchorPoint.x, 96)
        XCTAssertEqual(normalByID[absolute.id]?.anchorPoint.y, 88)
        XCTAssertEqual(reverseByID[absolute.id]?.anchorPoint, CGPoint(x: 96, y: 88))
    }

    private func makeCue(
        template: KaraokeTemplateConfiguration
    ) throws -> ResolvedSubtitleCue {
        let program = try XCTUnwrap(
            KaraokeProgram.evenlyTimed(
                text: "君のこと",
                duration: 2,
                template: template
            )
        )
        var style = ResolvedSubtitleStyle.fallback
        style.fontSize = 72
        style.alignment = .bottomCenter
        return ResolvedSubtitleCue(
            id: UUID(),
            text: "君のこと",
            startTime: 10,
            endTime: 12,
            style: style,
            groupID: nil,
            trackIndex: 0,
            layer: 0,
            position: nil,
            karaoke: program
        )
    }

    private func sceneCue(
        track: Int,
        layer: Int,
        position: ResolvedSubtitlePosition? = nil
    ) -> ResolvedSubtitleCue {
        ResolvedSubtitleCue(
            id: UUID(),
            text: "Track \(track)",
            startTime: 0,
            endTime: 10,
            style: .fallback,
            groupID: nil,
            trackIndex: track,
            layer: layer,
            position: position
        )
    }

    private func pixelData(_ image: CGImage) -> Data {
        guard let provider = image.dataProvider,
            let data = provider.data
        else {
            return Data()
        }
        return data as Data
    }
}
