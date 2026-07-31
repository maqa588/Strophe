//
//  KaraokeFrameRenderer.swift
//  Strophe
//
//  Layout and glyph layers are cached. A frame only evaluates timing, clips
//  cached layers, applies small effects and composites them.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

nonisolated struct KaraokeUnitRenderState: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case upcoming
        case active
        case completed
    }

    var unitID: UUID
    var phase: Phase
    var progress: Double
}

nonisolated enum KaraokeFrameStateEvaluator {
    static func states(
        program: KaraokeProgram,
        cueLocalTime: Double
    ) -> [KaraokeUnitRenderState] {
        states(units: program.units, cueLocalTime: cueLocalTime)
    }

    static func states(
        units: [KaraokeTimingUnit],
        cueLocalTime: Double
    ) -> [KaraokeUnitRenderState] {
        units.map { unit in
            if cueLocalTime < unit.startOffset {
                return KaraokeUnitRenderState(
                    unitID: unit.id,
                    phase: .upcoming,
                    progress: 0
                )
            }
            if cueLocalTime >= unit.endOffset {
                return KaraokeUnitRenderState(
                    unitID: unit.id,
                    phase: .completed,
                    progress: 1
                )
            }
            return KaraokeUnitRenderState(
                unitID: unit.id,
                phase: .active,
                progress: unit.progress(at: cueLocalTime)
            )
        }
    }
}

nonisolated final class KaraokeFrameRenderer: @unchecked Sendable {
    struct CacheStatistics: Sendable, Equatable {
        var assetCount: Int
        var assetBuildCount: Int
    }

    static let shared = KaraokeFrameRenderer()

    private let lock = NSLock()
    private let context: CIContext
    private var cache: [CacheKey: CacheEntry] = [:]
    private var assetBuildCount = 0
    private var accessSerial: UInt64 = 0

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        if let device {
            context = CIContext(
                mtlDevice: device,
                options: [
                    .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
                    .outputPremultiplied: true,
                ]
            )
        } else {
            context = CIContext(
                options: [
                    .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
                    .outputPremultiplied: true,
                ]
            )
        }
    }

    func metrics(
        cue: ResolvedSubtitleCue,
        canvasSize: CGSize
    ) -> SubtitleBitmapMetrics? {
        guard cue.karaoke?.isEnabled == true else { return nil }
        return asset(for: cue, canvasSize: canvasSize)?.metrics
    }

    func makeCIImage(
        cue: ResolvedSubtitleCue,
        presentationTime: Double,
        canvasSize: CGSize
    ) -> CIImage? {
        guard let program = cue.karaoke,
            program.isEnabled,
            let asset = asset(for: cue, canvasSize: canvasSize)
        else {
            return nil
        }
        let sourceBounds = CGRect(origin: .zero, size: asset.sourceSize)
        let transparentSourceCanvas = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        )
        .cropped(to: sourceBounds)
        var output = CIImage(cgImage: asset.baseImage)
            .transformed(
                by: CGAffineTransform(
                    translationX: asset.baseOrigin.x,
                    y: asset.baseOrigin.y
                )
            )
            .cropped(to: sourceBounds)
            .composited(over: transparentSourceCanvas)
            .cropped(to: sourceBounds)

        let localTime = presentationTime - cue.startTime
        let cueDuration = max(0.000_001, cue.endTime - cue.startTime)
        let liveUnits =
            program
            .repairingInvalidTiming(cueDuration: cueDuration)
            .validUnits(for: cue.text, cueDuration: cueDuration)
        let states = Dictionary(
            uniqueKeysWithValues: KaraokeFrameStateEvaluator.states(
                units: liveUnits,
                cueLocalTime: localTime
            ).map { ($0.unitID, $0) }
        )

        for layer in asset.unitLayers {
            guard let state = states[layer.unit.id],
                state.phase != .upcoming
            else {
                continue
            }
            let fullLayer = CIImage(cgImage: layer.image)
            let revealed: CIImage
            switch (program.template.revealMode, state.phase) {
            case (_, .completed), (.step, .active):
                revealed = fullLayer
            case (.sweep, .active):
                let progress = CGFloat(min(max(state.progress, 0), 1))
                let width = max(0, fullLayer.extent.width * progress)
                guard width > 0 else { continue }
                let x =
                    layer.isRightToLeft
                    ? fullLayer.extent.maxX - width
                    : fullLayer.extent.minX
                revealed = fullLayer.cropped(
                    to: CGRect(
                        x: x,
                        y: fullLayer.extent.minY,
                        width: width,
                        height: fullLayer.extent.height
                    )
                )
            case (_, .upcoming):
                continue
            }

            var positioned = revealed.transformed(
                by: CGAffineTransform(
                    translationX: layer.origin.x,
                    y: layer.origin.y
                )
            )
            if state.phase == .active, program.template.popScale > 1.000_1 {
                let pulse = sin(.pi * min(max(state.progress, 0), 1))
                let scale = CGFloat(
                    1 + (program.template.popScale - 1) * pulse
                )
                positioned = scaled(
                    positioned,
                    by: scale,
                    around: CGPoint(
                        x: layer.origin.x + CGFloat(layer.image.width) / 2,
                        y: layer.origin.y + CGFloat(layer.image.height) / 2
                    )
                )
            }

            if state.phase == .active,
                program.template.glowRadius > 0,
                program.template.glowIntensity > 0
            {
                let glow =
                    positioned
                    .applyingFilter(
                        "CIGaussianBlur",
                        parameters: [
                            kCIInputRadiusKey: program.template.glowRadius
                        ]
                    )
                    .applyingFilter(
                        "CIColorMatrix",
                        parameters: [
                            "inputAVector": CIVector(
                                x: 0,
                                y: 0,
                                z: 0,
                                w: program.template.glowIntensity
                            )
                        ]
                    )
                    .cropped(to: sourceBounds)
                output = glow.composited(over: output)
            }
            output =
                positioned
                .cropped(to: sourceBounds)
                .composited(over: output)
        }

        var transformed =
            output
            .cropped(to: sourceBounds)
            .transformed(by: asset.sourceToOutputTransform)
        let extent = transformed.extent
        if abs(extent.minX) > 0.000_1 || abs(extent.minY) > 0.000_1 {
            transformed = transformed.transformed(
                by: CGAffineTransform(
                    translationX: -extent.minX,
                    y: -extent.minY
                )
            )
        }
        let outputBounds = CGRect(
            origin: .zero,
            size: asset.metrics.size
        )
        let transparentOutputCanvas = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        )
        .cropped(to: outputBounds)
        return
            transformed
            .cropped(to: outputBounds)
            .composited(over: transparentOutputCanvas)
            .cropped(to: outputBounds)
    }

    func makeCGImage(
        cue: ResolvedSubtitleCue,
        presentationTime: Double,
        canvasSize: CGSize
    ) -> CGImage? {
        guard
            let image = makeCIImage(
                cue: cue,
                presentationTime: presentationTime,
                canvasSize: canvasSize
            )
        else {
            return nil
        }
        return context.createCGImage(
            image,
            from: CGRect(origin: .zero, size: image.extent.size)
        )
    }

    func clearCache() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func cacheStatistics() -> CacheStatistics {
        lock.lock()
        defer { lock.unlock() }
        return CacheStatistics(
            assetCount: cache.count,
            assetBuildCount: assetBuildCount
        )
    }

    private func asset(
        for cue: ResolvedSubtitleCue,
        canvasSize: CGSize
    ) -> SubtitleBitmapRenderer.KaraokeAsset? {
        guard cue.karaoke?.isEnabled == true else { return nil }
        let key = CacheKey(cue: cue, canvasSize: canvasSize)
        lock.lock()
        accessSerial &+= 1
        if var cached = cache[key] {
            cached.lastAccess = accessSerial
            cache[key] = cached
            lock.unlock()
            return cached.asset
        }
        lock.unlock()

        guard
            let built = SubtitleBitmapRenderer.makeKaraokeAsset(
                cue: cue,
                canvasSize: canvasSize
            )
        else {
            return nil
        }
        lock.lock()
        accessSerial &+= 1
        if var cached = cache[key] {
            // Preview and export may request the same new cue concurrently.
            // Keep the first compiled asset and discard this duplicate build.
            cached.lastAccess = accessSerial
            cache[key] = cached
            lock.unlock()
            return cached.asset
        }
        if cache.count >= 32,
            let leastRecentlyUsed = cache.min(
                by: { $0.value.lastAccess < $1.value.lastAccess }
            )?.key
        {
            cache.removeValue(forKey: leastRecentlyUsed)
        }
        cache[key] = CacheEntry(
            asset: built,
            lastAccess: accessSerial
        )
        assetBuildCount += 1
        lock.unlock()
        return built
    }

    private func scaled(
        _ image: CIImage,
        by scale: CGFloat,
        around center: CGPoint
    ) -> CIImage {
        image.transformed(
            by: CGAffineTransform(
                a: scale,
                b: 0,
                c: 0,
                d: scale,
                tx: center.x * (1 - scale),
                ty: center.y * (1 - scale)
            )
        )
    }

    private struct CacheKey: Hashable {
        var text: String
        var style: ResolvedSubtitleStyle
        var anchor: SubtitleStyle.Alignment
        var units: [UnitSignature]
        var inactiveColorHex: String
        var activeColorHex: String
        var popScale: Double
        var glowRadius: Double
        var width: Int
        var height: Int

        init(cue: ResolvedSubtitleCue, canvasSize: CGSize) {
            let program =
                cue.karaoke
                ?? KaraokeProgram(
                    textSnapshot: cue.text,
                    units: []
                )
            let cueDuration = max(0, cue.endTime - cue.startTime)
            let renderProgram = program.repairingInvalidTiming(
                cueDuration: cueDuration
            )
            text = cue.text
            style = cue.style
            anchor = cue.resolvedAnchor
            units =
                renderProgram
                .validUnits(for: cue.text, cueDuration: cueDuration)
                .map(UnitSignature.init)
            inactiveColorHex = program.template.inactiveColorHex
            activeColorHex = program.template.activeColorHex
            popScale = program.template.popScale
            glowRadius = program.template.glowRadius
            width = Int(canvasSize.width.rounded())
            height = Int(canvasSize.height.rounded())
        }
    }

    /// Only values that change shaped pixels or the maximum effect canvas belong
    /// in the asset key. Timing, reveal mode and effect intensity are evaluated
    /// per frame and therefore must not trigger another CoreText raster pass.
    private struct UnitSignature: Hashable {
        var id: UUID
        var characterStart: Int
        var characterLength: Int

        init(_ unit: KaraokeTimingUnit) {
            id = unit.id
            characterStart = unit.characterStart
            characterLength = unit.characterLength
        }
    }

    private struct CacheEntry {
        var asset: SubtitleBitmapRenderer.KaraokeAsset
        var lastAccess: UInt64
    }
}
