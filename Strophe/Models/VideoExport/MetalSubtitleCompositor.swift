import AVFoundation
import CoreImage
import CoreText
import Metal
import SwiftUI

enum SubtitleCompositorError: LocalizedError {
    case outputPoolUnavailable
    case pixelBufferCreationFailed
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .outputPoolUnavailable:
            return String(localized: "unable_to_create_video_output")
        case .pixelBufferCreationFailed:
            return String(localized: "unable_to_create_video_output_1")
        case .renderFailed:
            return String(localized: "hard_subtitle_frame_composition_failed")
        }
    }
}

nonisolated final class MetalSubtitleCompositor: @unchecked Sendable {
    private let context: CIContext
    private let outputColorProfile: VideoColorProfile
    private let rendersTransparentBackground: Bool
    private let overlays: VideoBurnInOverlaySettings
    private var bitmapCache: [SubtitleBitmapCacheKey: SubtitleBitmapRenderer.RenderedBitmap] = [:]

    init(
        outputColorProfile: VideoColorProfile = .sdr709,
        rendersTransparentBackground: Bool = false,
        overlays: VideoBurnInOverlaySettings = VideoBurnInOverlaySettings(),
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) {
        self.outputColorProfile = outputColorProfile
        self.rendersTransparentBackground = rendersTransparentBackground
        self.overlays = overlays
        let options: [CIContextOption: Any] = [
            .workingColorSpace: outputColorProfile.workingColorSpace,
            .outputPremultiplied: true
        ]
        if let device {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    func render(
        sourcePixelBuffer: CVPixelBuffer,
        outputPixelBuffer: CVPixelBuffer,
        scene: SubtitleFrameScene,
        renderSize: CGSize,
        preferredTransform: CGAffineTransform,
        sourceDisplaySize: CGSize? = nil
    ) throws {
        let bounds = CGRect(origin: .zero, size: renderSize)
        var output: CIImage
        if rendersTransparentBackground {
            output = CIImage(
                color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            ).cropped(to: bounds)
        } else {
            let sourceProfile = VideoColorProfile.detect(in: sourcePixelBuffer)
            let imageOptions: [CIImageOption: Any] = outputColorProfile.isHDR
                ? [:]
                : [.toneMapHDRtoSDR: sourceProfile.isHDR]
            var image = CIImage(cvPixelBuffer: sourcePixelBuffer, options: imageOptions)
            if preferredTransform != .identity {
                image = image.transformed(by: preferredTransform)
                image = normalizeOrigin(image)
            }

            if let sourceDisplaySize,
               sourceDisplaySize.width > 0,
               sourceDisplaySize.height > 0,
               image.extent.width > 0,
               image.extent.height > 0 {
                let scaleX = sourceDisplaySize.width / image.extent.width
                let scaleY = sourceDisplaySize.height / image.extent.height
                image = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                image = normalizeOrigin(image)
            }

            let fittedImage = aspectFit(image: image, in: bounds)
            output = fittedImage.composited(
                over: CIImage(color: .black).cropped(to: bounds)
            )
        }

        for item in scene.items {
            guard var overlay = subtitleCIImage(
                for: item.cue,
                presentationTime: scene.presentationTime,
                canvasSize: renderSize
            ) else {
                continue
            }

            let coreImageOrigin = CGPoint(
                x: item.origin.x,
                y: renderSize.height - item.origin.y - item.size.height
            )
            overlay = overlay.transformed(
                by: CGAffineTransform(
                    translationX: coreImageOrigin.x.rounded(.down),
                    y: coreImageOrigin.y.rounded(.down)
                )
            )
            let opacity = item.cue.opacity(at: scene.presentationTime)
            if opacity < 1 {
                overlay = overlay.applyingFilter(
                    "CIColorMatrix",
                    parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
                    ]
                )
            }
            output = overlay.composited(over: output)
        }

        context.render(
            output,
            to: outputPixelBuffer,
            bounds: bounds,
            colorSpace: outputColorProfile.outputColorSpace
        )
        outputColorProfile.attachColorMetadata(
            to: outputPixelBuffer,
            copyingStaticHDRMetadataFrom: sourcePixelBuffer
        )
    }

    func makeFrameScene(
        cues: [ResolvedSubtitleCue],
        at presentationTime: Double,
        renderSize: CGSize,
        collisionMode: SubtitleCollisionMode
    ) -> SubtitleFrameScene {
        let cues = cues + exportOverlayCues(at: presentationTime)
        return SubtitleFrameSceneResolver.resolve(
            cues: cues,
            at: presentationTime,
            canvasSize: renderSize,
            collisionMode: collisionMode
        ) { [self] cue in
            if cue.karaoke != nil {
                return KaraokeFrameRenderer.shared.metrics(
                    cue: cue,
                    canvasSize: renderSize
                )
            }
            return subtitleBitmap(for: cue, canvasSize: renderSize)?.metrics
        }
    }

    private func exportOverlayCues(at presentationTime: Double) -> [ResolvedSubtitleCue] {
        var cues: [ResolvedSubtitleCue] = []
        if !overlays.watermarkText.isEmpty {
            cues.append(
                ResolvedSubtitleCue(
                    id: UUID(uuid: (0x53, 0x54, 0x52, 0x4F, 0x50, 0x48, 0x45, 0x57, 0x41, 0x54, 0x45, 0x52, 0x4D, 0x41, 0x52, 0x4B)),
                    text: overlays.watermarkText,
                    startTime: -.greatestFiniteMagnitude,
                    endTime: .greatestFiniteMagnitude,
                    style: overlayStyle(alignment: .topRight),
                    groupID: nil,
                    trackIndex: Int.max - 1,
                    layer: Int.max - 1,
                    position: nil
                )
            )
        }
        if overlays.burnsTimecode {
            let time = overlays.timecodeStartsAtZero
                ? max(0, presentationTime - overlays.timelineStartSeconds)
                : max(0, presentationTime)
            cues.append(
                ResolvedSubtitleCue(
                    id: UUID(uuid: (0x53, 0x54, 0x52, 0x4F, 0x50, 0x48, 0x45, 0x54, 0x49, 0x4D, 0x45, 0x43, 0x4F, 0x44, 0x45, 0x31)),
                    text: timecode(seconds: time, frameRate: overlays.frameRate),
                    startTime: -.greatestFiniteMagnitude,
                    endTime: .greatestFiniteMagnitude,
                    style: overlayStyle(alignment: .topLeft),
                    groupID: nil,
                    trackIndex: Int.max,
                    layer: Int.max,
                    position: nil
                )
            )
        }
        return cues
    }

    private func overlayStyle(
        alignment: SubtitleStyle.Alignment
    ) -> ResolvedSubtitleStyle {
        var style = ResolvedSubtitleStyle.fallback
        style.name = "Strophe Export Overlay"
        style.fontName = "Menlo"
        style.fontSize = 32
        style.outlineWidth = 1.5
        style.shadowRadius = 2
        style.backgroundColor = .black.withAlpha(0.55)
        style.alignment = alignment
        style.marginLeftPercent = 3
        style.marginRightPercent = 3
        style.marginVerticalPercent = 3
        return style
    }

    private func timecode(seconds: Double, frameRate: Double) -> String {
        let fps = max(1, Int(frameRate.rounded()))
        let totalFrames = max(0, Int((seconds * Double(fps)).rounded(.down)))
        let frames = totalFrames % fps
        let totalSeconds = totalFrames / fps
        return String(
            format: "%02d:%02d:%02d:%02d",
            totalSeconds / 3_600,
            (totalSeconds / 60) % 60,
            totalSeconds % 60,
            frames
        )
    }

    private func normalizeOrigin(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.origin != .zero else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
    }

    private func aspectFit(image: CIImage, in bounds: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, bounds.width > 0, bounds.height > 0 else {
            return image
        }

        let scale = min(bounds.width / extent.width, bounds.height / extent.height)
        let scaledWidth = extent.width * scale
        let scaledHeight = extent.height * scale
        let x = bounds.midX - scaledWidth / 2.0
        let y = bounds.midY - scaledHeight / 2.0

        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    private func subtitleImage(for cue: ResolvedSubtitleCue, canvasSize: CGSize) -> CGImage? {
        subtitleBitmap(for: cue, canvasSize: canvasSize)?.image
    }

    private func subtitleCIImage(
        for cue: ResolvedSubtitleCue,
        presentationTime: Double,
        canvasSize: CGSize
    ) -> CIImage? {
        if cue.karaoke != nil {
            return KaraokeFrameRenderer.shared.makeCIImage(
                cue: cue,
                presentationTime: presentationTime,
                canvasSize: canvasSize
            )
        }
        guard let image = subtitleImage(for: cue, canvasSize: canvasSize) else {
            return nil
        }
        return CIImage(
            cgImage: image,
            options: [
                .colorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
            ]
        )
    }

    private func subtitleBitmap(
        for cue: ResolvedSubtitleCue,
        canvasSize: CGSize
    ) -> SubtitleBitmapRenderer.RenderedBitmap? {
        let key = SubtitleBitmapCacheKey(cue: cue, canvasSize: canvasSize)
        if let cached = bitmapCache[key] {
            return cached
        }

        let bitmap = SubtitleBitmapRenderer.makeBitmap(cue: cue, canvasSize: canvasSize)
        if let bitmap {
            bitmapCache[key] = bitmap
        }

        if bitmapCache.count > 128 {
            bitmapCache.removeAll(keepingCapacity: true)
        }

        return bitmap
    }
}

nonisolated private struct SubtitleBitmapCacheKey: Hashable {
    var text: String
    var style: ResolvedSubtitleStyle
    var anchor: SubtitleStyle.Alignment
    var width: Int
    var height: Int

    init(cue: ResolvedSubtitleCue, canvasSize: CGSize) {
        text = cue.text
        style = cue.style
        anchor = cue.resolvedAnchor
        width = Int(canvasSize.width.rounded())
        height = Int(canvasSize.height.rounded())
    }
}

nonisolated enum SubtitleBitmapRenderer {
    struct RenderedBitmap {
        var image: CGImage
        var metrics: SubtitleBitmapMetrics
    }

    struct KaraokeUnitLayer {
        var unit: KaraokeTimingUnit
        /// A tightly cropped, fill-only image in untransformed cue space.
        var image: CGImage
        /// Bottom-left origin in the padded, untransformed cue canvas.
        var origin: CGPoint
        var isRightToLeft: Bool
    }

    struct KaraokeAsset {
        var baseImage: CGImage
        var baseOrigin: CGPoint
        var sourceSize: CGSize
        var metrics: SubtitleBitmapMetrics
        var sourceToOutputTransform: CGAffineTransform
        var unitLayers: [KaraokeUnitLayer]
    }

    static func makeImage(cue: ResolvedSubtitleCue, canvasSize: CGSize) -> CGImage? {
        makeBitmap(cue: cue, canvasSize: canvasSize)?.image
    }

    static func makeImage(text: String, style: ResolvedSubtitleStyle, canvasSize: CGSize) -> CGImage? {
        makeBitmap(
            text: text,
            style: style,
            anchor: style.alignment,
            canvasSize: canvasSize
        )?.image
    }

    static func makeBitmap(
        cue: ResolvedSubtitleCue,
        canvasSize: CGSize
    ) -> RenderedBitmap? {
        makeBitmap(
            text: cue.text,
            style: cue.style,
            anchor: cue.resolvedAnchor,
            canvasSize: canvasSize
        )
    }

    static func metrics(
        cue: ResolvedSubtitleCue,
        canvasSize: CGSize
    ) -> SubtitleBitmapMetrics? {
        makeLayout(
            text: cue.text,
            style: cue.style,
            anchor: cue.resolvedAnchor,
            canvasSize: canvasSize
        )?.metrics
    }

    static func makeBitmap(
        text: String,
        style: ResolvedSubtitleStyle,
        anchor: SubtitleStyle.Alignment,
        canvasSize: CGSize
    ) -> RenderedBitmap? {
        guard let layout = makeLayout(
            text: text,
            style: style,
            anchor: anchor,
            canvasSize: canvasSize
        ) else {
            return nil
        }

        guard let baseImage = makeBaseImage(layout: layout, style: style) else {
            return nil
        }
        return transformedBitmap(
            baseImage,
            scaleX: style.scaleX,
            scaleY: style.scaleY,
            rotationDegrees: style.rotationDegrees,
            anchor: anchor
        )
    }

    static func makeKaraokeAsset(
        cue: ResolvedSubtitleCue,
        canvasSize: CGSize
    ) -> KaraokeAsset? {
        guard let program = cue.karaoke, program.isEnabled else { return nil }
        let duration = max(0, cue.endTime - cue.startTime)
        let renderProgram = program.repairingInvalidTiming(
            cueDuration: duration
        )
        let units = renderProgram.validUnits(
            for: cue.text,
            cueDuration: duration
        )
        guard !units.isEmpty else { return nil }

        var inactiveStyle = cue.style
        if let inactive = ResolvedRGBAColor(
            hex: renderProgram.template.inactiveColorHex
        ) {
            inactiveStyle.textColor = inactive
        }
        guard let layout = makeLayout(
            text: cue.text,
            style: inactiveStyle,
            anchor: cue.resolvedAnchor,
            canvasSize: canvasSize
        ), let baseImage = makeBaseImage(
            layout: layout,
            style: inactiveStyle
        ) else {
            return nil
        }

        let activeColor = ResolvedRGBAColor(
            hex: renderProgram.template.activeColorHex
        ) ?? cue.style.textColor
        let rawLayers = units.compactMap {
            makeKaraokeUnitLayer(
                unit: $0,
                text: cue.text,
                layout: layout,
                activeColor: activeColor,
                effectPadding: 0
            )
        }
        guard !rawLayers.isEmpty else { return nil }

        // Pop scales a complete timing unit, so its maximum excursion depends
        // on the actual shaped word width—not merely the font size. Glow is
        // applied after Pop and therefore its blur support must be added.
        let maxUnitWidth = rawLayers.map {
            Double($0.image.width)
        }.max() ?? 0
        let maxUnitHeight = rawLayers.map {
            Double($0.image.height)
        }.max() ?? 0
        let effectPadding = CGFloat(
            renderProgram.template.maximumOutset(
                maxUnitWidth: maxUnitWidth,
                maxUnitHeight: maxUnitHeight
            )
        )
        let layers = rawLayers.map { layer in
            var padded = layer
            padded.origin.x += effectPadding
            padded.origin.y += effectPadding
            return padded
        }
        let sourceSize = CGSize(
            width: layout.baseSize.width + effectPadding * 2,
            height: layout.baseSize.height + effectPadding * 2
        )
        let textAnchor = sourceAnchor(
            for: cue.resolvedAnchor,
            sourceSize: layout.baseSize
        )
        let geometry = transformedGeometry(
            sourceSize: sourceSize,
            scaleX: CGFloat(max(0.05, min(10, cue.style.scaleX))),
            scaleY: CGFloat(max(0.05, min(10, cue.style.scaleY))),
            radians: CGFloat(cue.style.rotationDegrees * .pi / 180),
            anchor: cue.resolvedAnchor,
            explicitSourceAnchor: CGPoint(
                x: textAnchor.x + effectPadding,
                y: textAnchor.y + effectPadding
            )
        )

        return KaraokeAsset(
            baseImage: baseImage,
            baseOrigin: CGPoint(x: effectPadding, y: effectPadding),
            sourceSize: sourceSize,
            metrics: geometry.metrics,
            sourceToOutputTransform: geometry.affineTransform,
            unitLayers: layers
        )
    }

    private static func makeBaseImage(
        layout: BitmapLayout,
        style: ResolvedSubtitleStyle
    ) -> CGImage? {
        let width = Int(layout.baseSize.width)
        let height = Int(layout.baseSize.height)
        guard width > 0, height > 0,
              let context = makeBitmapContext(width: width, height: height) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        if let backgroundColor = style.backgroundColor {
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(backgroundColor.cgColor)
            context.addPath(
                CGPath(
                    roundedRect: rect,
                    cornerWidth: max(8, 12 * layout.canvasScale),
                    cornerHeight: max(8, 12 * layout.canvasScale),
                    transform: nil
                )
            )
            context.fillPath()
        }

        let textRect = layout.textRect
        if layout.outline > 0 {
            let outlineAttributed = NSMutableAttributedString(
                attributedString: layout.attributed
            )
            outlineAttributed.addAttribute(
                .foregroundColor,
                value: style.outlineColor.cgColor,
                range: NSRange(location: 0, length: outlineAttributed.length)
            )
            drawOutlinedText(
                outlineAttributed,
                in: textRect,
                context: context,
                radius: layout.outline
            )
        }

        if style.dropShadowOffset > 0 && style.dropShadowColor.alpha > 0 {
            let radians = style.dropShadowAngle * .pi / 180.0
            let dx = style.dropShadowOffset * layout.canvasScale * cos(radians)
            let dy = -style.dropShadowOffset * layout.canvasScale * sin(radians)
            context.setShadow(
                offset: CGSize(width: dx, height: dy),
                blur: 1.5,
                color: style.dropShadowColor.cgColor
            )
            draw(layout.attributed, in: textRect, context: context)
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }

        context.setShadow(
            offset: CGSize(width: 0, height: -max(1, layout.shadow * 0.35)),
            blur: layout.shadow,
            color: style.shadowColor.cgColor
        )
        draw(layout.attributed, in: textRect, context: context)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        return context.makeImage()
    }

    private struct BitmapLayout {
        var attributed: NSAttributedString
        var suggestedTextSize: CGSize
        var baseSize: CGSize
        var horizontalPadding: CGFloat
        var verticalPadding: CGFloat
        var outline: CGFloat
        var shadow: CGFloat
        var canvasScale: CGFloat
        var metrics: SubtitleBitmapMetrics

        var textRect: CGRect {
            CGRect(
                x: horizontalPadding,
                y: verticalPadding,
                width: suggestedTextSize.width,
                height: suggestedTextSize.height
            )
        }
    }

    private static func makeKaraokeUnitLayer(
        unit: KaraokeTimingUnit,
        text: String,
        layout: BitmapLayout,
        activeColor: ResolvedRGBAColor,
        effectPadding: CGFloat
    ) -> KaraokeUnitLayer? {
        guard let utf16Range = utf16Range(
            characterStart: unit.characterStart,
            characterLength: unit.characterLength,
            in: text
        ) else {
            return nil
        }
        let geometry = karaokeGeometry(
            for: utf16Range,
            attributed: layout.attributed,
            textRect: layout.textRect
        )
        guard !geometry.rects.isEmpty else { return nil }

        let rawBounds = geometry.rects.reduce(CGRect.null) {
            $0.union($1)
        }
        let bounds = rawBounds
            .insetBy(dx: -2, dy: -2)
            .intersection(CGRect(origin: .zero, size: layout.baseSize))
            .integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 0, height > 0,
              let context = makeBitmapContext(width: width, height: height) else {
            return nil
        }

        let highlighted = NSMutableAttributedString(
            attributedString: layout.attributed
        )
        highlighted.addAttribute(
            .foregroundColor,
            value: CGColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: 0
            ),
            range: NSRange(location: 0, length: highlighted.length)
        )
        highlighted.addAttribute(
            .foregroundColor,
            value: activeColor.cgColor,
            range: utf16Range
        )

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        draw(highlighted, in: layout.textRect, context: context)
        guard let image = context.makeImage() else { return nil }
        return KaraokeUnitLayer(
            unit: unit,
            image: image,
            origin: CGPoint(
                x: bounds.minX + effectPadding,
                y: bounds.minY + effectPadding
            ),
            isRightToLeft: geometry.isRightToLeft
        )
    }

    private struct KaraokeGeometry {
        var rects: [CGRect]
        var isRightToLeft: Bool
    }

    private static func karaokeGeometry(
        for targetRange: NSRange,
        attributed: NSAttributedString,
        textRect: CGRect
    ) -> KaraokeGeometry {
        let path = CGMutablePath()
        path.addRect(textRect)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        if !origins.isEmpty {
            CTFrameGetLineOrigins(
                frame,
                CFRange(location: 0, length: lines.count),
                &origins
            )
        }

        let targetStart = targetRange.location
        let targetEnd = targetRange.location + targetRange.length
        var rects: [CGRect] = []
        var rtlGlyphCount = 0
        var glyphCount = 0

        for (index, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            let lineStart = lineRange.location
            let lineEnd = lineRange.location + lineRange.length
            let intersectionStart = max(targetStart, lineStart)
            let intersectionEnd = min(targetEnd, lineEnd)
            guard intersectionEnd > intersectionStart else { continue }

            var secondaryStart: CGFloat = 0
            var secondaryEnd: CGFloat = 0
            let primaryStart = CTLineGetOffsetForStringIndex(
                line,
                intersectionStart,
                &secondaryStart
            )
            let primaryEnd = CTLineGetOffsetForStringIndex(
                line,
                intersectionEnd,
                &secondaryEnd
            )
            let offsets = [
                primaryStart,
                secondaryStart,
                primaryEnd,
                secondaryEnd
            ]
            let minX = offsets.min() ?? primaryStart
            let maxX = offsets.max() ?? primaryEnd
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(
                line,
                &ascent,
                &descent,
                &leading
            )
            rects.append(
                CGRect(
                    x: origins[index].x + minX,
                    y: origins[index].y - descent,
                    width: max(1, maxX - minX),
                    height: max(1, ascent + descent + leading)
                )
            )

            let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
            for run in runs {
                let range = CTRunGetStringRange(run)
                let runStart = range.location
                let runEnd = range.location + range.length
                guard min(intersectionEnd, runEnd) > max(intersectionStart, runStart) else {
                    continue
                }
                let count = CTRunGetGlyphCount(run)
                glyphCount += count
                if CTRunGetStatus(run).contains(.rightToLeft) {
                    rtlGlyphCount += count
                }
            }
        }
        return KaraokeGeometry(
            rects: rects,
            isRightToLeft: rtlGlyphCount > glyphCount / 2
        )
    }

    private static func utf16Range(
        characterStart: Int,
        characterLength: Int,
        in text: String
    ) -> NSRange? {
        let characters = Array(text)
        guard characterStart >= 0,
              characterLength > 0,
              characterStart + characterLength <= characters.count else {
            return nil
        }
        let prefix = String(characters.prefix(characterStart))
        let selection = String(
            characters[
                characterStart..<(characterStart + characterLength)
            ]
        )
        return NSRange(
            location: prefix.utf16.count,
            length: selection.utf16.count
        )
    }

    private static func makeBitmapContext(
        width: Int,
        height: Int
    ) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func makeLayout(
        text: String,
        style: ResolvedSubtitleStyle,
        anchor: SubtitleStyle.Alignment,
        canvasSize: CGSize
    ) -> BitmapLayout? {
        let scale = max(0.42, min(canvasSize.height / 1080.0, 2.2))
        let fontSize = max(18, style.fontSize * scale)
        let placementRect = SubtitlePlacementMetrics.placementRect(
            for: canvasSize,
            style: style
        )
        let maxTextWidth = max(1, placementRect.width)
        let paragraph = makeParagraphStyle(alignment: style.alignment)
        let font = makeFont(style: style, size: fontSize)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.textColor.cgColor,
            .paragraphStyle: paragraph,
            .kern: style.characterSpacing * scale
        ]
        if style.isUnderline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.isStrikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        let attributed = NSAttributedString(
            string: text,
            attributes: attributes
        )

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            nil,
            CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            nil
        )

        let outline = max(0, style.outlineWidth * scale)
        let dropShadow = style.dropShadowColor.alpha > 0 ? max(0, style.dropShadowOffset * scale) : 0
        let shadow = max(0, max(style.shadowRadius * scale, dropShadow))
        let horizontalPadding = style.backgroundColor == nil ? outline + shadow : max(22 * scale, outline + shadow)
        let verticalPadding = style.backgroundColor == nil ? outline + shadow : max(12 * scale, outline + shadow)
        let width = Int(ceil(suggested.width + horizontalPadding * 2))
        let height = Int(ceil(suggested.height + verticalPadding * 2))
        guard width > 0, height > 0 else { return nil }

        let baseSize = CGSize(width: width, height: height)
        let metrics = transformedMetrics(
            sourceSize: baseSize,
            scaleX: style.scaleX,
            scaleY: style.scaleY,
            rotationDegrees: style.rotationDegrees,
            anchor: anchor
        )
        return BitmapLayout(
            attributed: attributed,
            suggestedTextSize: suggested,
            baseSize: baseSize,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            outline: outline,
            shadow: shadow,
            canvasScale: scale,
            metrics: metrics
        )
    }

    private static func transformedBitmap(
        _ image: CGImage,
        scaleX rawScaleX: Double,
        scaleY rawScaleY: Double,
        rotationDegrees: Double,
        anchor: SubtitleStyle.Alignment
    ) -> RenderedBitmap? {
        let scaleX = CGFloat(max(0.05, min(10, rawScaleX)))
        let scaleY = CGFloat(max(0.05, min(10, rawScaleY)))
        let radians = CGFloat(rotationDegrees * .pi / 180)
        let sourceSize = CGSize(width: image.width, height: image.height)
        let geometry = transformedGeometry(
            sourceSize: sourceSize,
            scaleX: scaleX,
            scaleY: scaleY,
            radians: radians,
            anchor: anchor
        )

        guard abs(scaleX - 1) > 0.0001 || abs(scaleY - 1) > 0.0001 || abs(radians) > 0.0001 else {
            return RenderedBitmap(image: image, metrics: geometry.metrics)
        }

        let outputWidth = Int(geometry.metrics.size.width)
        let outputHeight = Int(geometry.metrics.size.height)

        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.translateBy(
            x: geometry.anchorDestination.x,
            y: geometry.anchorDestination.y
        )
        context.rotate(by: radians)
        context.scaleBy(x: scaleX, y: scaleY)
        context.translateBy(
            x: -geometry.anchorSource.x,
            y: -geometry.anchorSource.y
        )
        context.draw(
            image,
            in: CGRect(origin: .zero, size: sourceSize)
        )
        guard let transformed = context.makeImage() else { return nil }
        return RenderedBitmap(image: transformed, metrics: geometry.metrics)
    }

    private struct TransformedGeometry {
        var metrics: SubtitleBitmapMetrics
        var anchorSource: CGPoint
        var anchorDestination: CGPoint
        var affineTransform: CGAffineTransform
    }

    private static func transformedMetrics(
        sourceSize: CGSize,
        scaleX rawScaleX: Double,
        scaleY rawScaleY: Double,
        rotationDegrees: Double,
        anchor: SubtitleStyle.Alignment
    ) -> SubtitleBitmapMetrics {
        transformedGeometry(
            sourceSize: sourceSize,
            scaleX: CGFloat(max(0.05, min(10, rawScaleX))),
            scaleY: CGFloat(max(0.05, min(10, rawScaleY))),
            radians: CGFloat(rotationDegrees * .pi / 180),
            anchor: anchor
        ).metrics
    }

    private static func transformedGeometry(
        sourceSize: CGSize,
        scaleX: CGFloat,
        scaleY: CGFloat,
        radians: CGFloat,
        anchor: SubtitleStyle.Alignment,
        explicitSourceAnchor: CGPoint? = nil
    ) -> TransformedGeometry {
        let anchorSource = explicitSourceAnchor ?? sourceAnchor(
            for: anchor,
            sourceSize: sourceSize
        )
        let cosine = cos(radians)
        let sine = sin(radians)
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: sourceSize.width, y: 0),
            CGPoint(x: 0, y: sourceSize.height),
            CGPoint(x: sourceSize.width, y: sourceSize.height)
        ].map { point -> CGPoint in
            let scaledX = (point.x - anchorSource.x) * scaleX
            let scaledY = (point.y - anchorSource.y) * scaleY
            return CGPoint(
                x: scaledX * cosine - scaledY * sine,
                y: scaledX * sine + scaledY * cosine
            )
        }

        let minX = corners.map(\.x).min() ?? 0
        let maxX = corners.map(\.x).max() ?? 0
        let minY = corners.map(\.y).min() ?? 0
        let maxY = corners.map(\.y).max() ?? 0
        let outputSize = CGSize(
            width: max(1, ceil(maxX - minX)),
            height: max(1, ceil(maxY - minY))
        )
        let anchorDestination = CGPoint(x: -minX, y: -minY)
        let anchorOffset = CGPoint(
            x: anchorDestination.x,
            y: outputSize.height - anchorDestination.y
        )
        return TransformedGeometry(
            metrics: SubtitleBitmapMetrics(
                size: outputSize,
                anchorOffset: anchorOffset
            ),
            anchorSource: anchorSource,
            anchorDestination: anchorDestination,
            affineTransform: CGAffineTransform(
                a: scaleX * cosine,
                b: scaleX * sine,
                c: -scaleY * sine,
                d: scaleY * cosine,
                tx: anchorDestination.x
                    - anchorSource.x * scaleX * cosine
                    + anchorSource.y * scaleY * sine,
                ty: anchorDestination.y
                    - anchorSource.x * scaleX * sine
                    - anchorSource.y * scaleY * cosine
            )
        )
    }

    private static func sourceAnchor(
        for alignment: SubtitleStyle.Alignment,
        sourceSize: CGSize
    ) -> CGPoint {
        let x: CGFloat
        switch alignment {
        case .topLeft, .middleLeft, .bottomLeft:
            x = 0
        case .topCenter, .middleCenter, .bottomCenter:
            x = sourceSize.width / 2
        case .topRight, .middleRight, .bottomRight:
            x = sourceSize.width
        }

        // Core Graphics image coordinates use a bottom-left origin.
        let y: CGFloat
        switch alignment {
        case .topLeft, .topCenter, .topRight:
            y = sourceSize.height
        case .middleLeft, .middleCenter, .middleRight:
            y = sourceSize.height / 2
        case .bottomLeft, .bottomCenter, .bottomRight:
            y = 0
        }
        return CGPoint(x: x, y: y)
    }

    private static func makeFont(style: ResolvedSubtitleStyle, size: CGFloat) -> CTFont {
        let base: CTFont
        if let fontName = style.fontName, !fontName.isEmpty {
            base = CTFontCreateWithName(fontName as CFString, size, nil)
        } else {
            base = CTFontCreateUIFontForLanguage(style.isBold ? .emphasizedSystem : .system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }

        var traits: CTFontSymbolicTraits = []
        if style.isBold { traits.insert(.boldTrait) }
        if style.isItalic { traits.insert(.italicTrait) }

        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
    }

    private static func makeParagraphStyle(alignment: SubtitleStyle.Alignment) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        switch alignment {
        case .topLeft, .middleLeft, .bottomLeft:
            paragraph.alignment = .left
        case .topCenter, .middleCenter, .bottomCenter:
            paragraph.alignment = .center
        case .topRight, .middleRight, .bottomRight:
            paragraph.alignment = .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        return paragraph
    }

    private static func drawOutlinedText(
        _ attributed: NSAttributedString,
        in rect: CGRect,
        context: CGContext,
        radius: CGFloat
    ) {
        let offsets: [CGPoint] = [
            CGPoint(x: -radius, y: 0),
            CGPoint(x: radius, y: 0),
            CGPoint(x: 0, y: -radius),
            CGPoint(x: 0, y: radius),
            CGPoint(x: -radius * 0.72, y: -radius * 0.72),
            CGPoint(x: radius * 0.72, y: -radius * 0.72),
            CGPoint(x: -radius * 0.72, y: radius * 0.72),
            CGPoint(x: radius * 0.72, y: radius * 0.72)
        ]

        for offset in offsets {
            draw(attributed, in: rect.offsetBy(dx: offset.x, dy: offset.y), context: context)
        }
    }

    private static func draw(_ attributed: NSAttributedString, in rect: CGRect, context: CGContext) {
        let path = CGMutablePath()
        path.addRect(rect)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        CTFrameDraw(frame, context)
    }
}
