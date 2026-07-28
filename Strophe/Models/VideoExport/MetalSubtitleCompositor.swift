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
            guard let subtitle = subtitleImage(
                for: item.cue,
                canvasSize: renderSize
            ) else {
                continue
            }

            let coreImageOrigin = CGPoint(
                x: item.origin.x,
                y: renderSize.height - item.origin.y - item.size.height
            )
            var overlay = CIImage(
                cgImage: subtitle,
                options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any]
            )
                .transformed(
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
            subtitleBitmap(for: cue, canvasSize: renderSize)?.metrics
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

        let width = Int(layout.baseSize.width)
        let height = Int(layout.baseSize.height)
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
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

        let textRect = CGRect(
            x: layout.horizontalPadding,
            y: layout.verticalPadding,
            width: layout.suggestedTextSize.width,
            height: layout.suggestedTextSize.height
        )

        if layout.outline > 0 {
            let outlineAttributed = NSMutableAttributedString(attributedString: layout.attributed)
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

        context.setShadow(
            offset: CGSize(width: 0, height: -max(1, layout.shadow * 0.35)),
            blur: layout.shadow,
            color: style.shadowColor.cgColor
        )
        draw(layout.attributed, in: textRect, context: context)
        context.setShadow(offset: .zero, blur: 0, color: nil)

        guard let baseImage = context.makeImage() else { return nil }
        return transformedBitmap(
            baseImage,
            scaleX: style.scaleX,
            scaleY: style.scaleY,
            rotationDegrees: style.rotationDegrees,
            anchor: anchor
        )
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
        let shadow = max(0, style.shadowRadius * scale)
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
        anchor: SubtitleStyle.Alignment
    ) -> TransformedGeometry {
        let anchorSource = sourceAnchor(
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
            anchorDestination: anchorDestination
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
