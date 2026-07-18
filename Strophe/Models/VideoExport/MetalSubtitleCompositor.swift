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
    private var bitmapCache: [SubtitleBitmapCacheKey: CGImage] = [:]

    init(
        outputColorProfile: VideoColorProfile = .sdr709,
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) {
        self.outputColorProfile = outputColorProfile
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
        cue: ResolvedSubtitleCue?,
        renderSize: CGSize,
        preferredTransform: CGAffineTransform,
        sourceDisplaySize: CGSize? = nil
    ) throws {
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

        let bounds = CGRect(origin: .zero, size: renderSize)
        let fittedImage = aspectFit(image: image, in: bounds)
        var output = fittedImage.composited(over: CIImage(color: .black).cropped(to: bounds))

        if let cue,
           let subtitle = subtitleImage(for: cue, canvasSize: renderSize) {
            let origin = subtitleOrigin(
                subtitleSize: CGSize(width: CGFloat(subtitle.width), height: CGFloat(subtitle.height)),
                canvasSize: renderSize,
                style: cue.style
            )
            let overlay = CIImage(
                cgImage: subtitle,
                options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any]
            )
                .transformed(
                    by: CGAffineTransform(
                        translationX: origin.x.rounded(.down),
                        y: origin.y.rounded(.down)
                    )
                )
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

    private func subtitleOrigin(
        subtitleSize: CGSize,
        canvasSize: CGSize,
        style: ResolvedSubtitleStyle
    ) -> CGPoint {
        let placementRect = SubtitlePlacementMetrics.placementRect(
            for: canvasSize,
            style: style
        )
        let alignment = style.alignment

        let x: CGFloat
        switch alignment {
        case .topLeft, .middleLeft, .bottomLeft:
            x = placementRect.minX
        case .topCenter, .middleCenter, .bottomCenter:
            x = placementRect.midX - subtitleSize.width / 2
        case .topRight, .middleRight, .bottomRight:
            x = placementRect.maxX - subtitleSize.width
        }

        // Core Image uses a bottom-left origin, so top and bottom are inverted
        // compared with the SwiftUI preview coordinate system.
        let y: CGFloat
        switch alignment {
        case .topLeft, .topCenter, .topRight:
            y = placementRect.maxY - subtitleSize.height
        case .middleLeft, .middleCenter, .middleRight:
            y = placementRect.midY - subtitleSize.height / 2
        case .bottomLeft, .bottomCenter, .bottomRight:
            y = placementRect.minY
        }

        return CGPoint(
            x: max(0, min(x, canvasSize.width - subtitleSize.width)),
            y: max(0, min(y, canvasSize.height - subtitleSize.height))
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
        let key = SubtitleBitmapCacheKey(cue: cue, canvasSize: canvasSize)
        if let cached = bitmapCache[key] {
            return cached
        }

        let image = SubtitleBitmapRenderer.makeImage(cue: cue, canvasSize: canvasSize)
        if let image {
            bitmapCache[key] = image
        }

        if bitmapCache.count > 128 {
            bitmapCache.removeAll(keepingCapacity: true)
        }

        return image
    }
}

nonisolated private struct SubtitleBitmapCacheKey: Hashable {
    var text: String
    var style: ResolvedSubtitleStyle
    var width: Int
    var height: Int

    init(cue: ResolvedSubtitleCue, canvasSize: CGSize) {
        text = cue.text
        style = cue.style
        width = Int(canvasSize.width.rounded())
        height = Int(canvasSize.height.rounded())
    }
}

nonisolated enum SubtitleBitmapRenderer {
    static func makeImage(cue: ResolvedSubtitleCue, canvasSize: CGSize) -> CGImage? {
        makeImage(text: cue.text, style: cue.style, canvasSize: canvasSize)
    }

    static func makeImage(text: String, style: ResolvedSubtitleStyle, canvasSize: CGSize) -> CGImage? {
        let scale = max(0.42, min(canvasSize.height / 1080.0, 2.2))
        let fontSize = max(18, style.fontSize * scale)
        let maxTextWidth = max(240, canvasSize.width * 0.82)
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
            context.addPath(CGPath(roundedRect: rect, cornerWidth: max(8, 12 * scale), cornerHeight: max(8, 12 * scale), transform: nil))
            context.fillPath()
        }

        let textRect = CGRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: suggested.width,
            height: suggested.height
        )

        if outline > 0 {
            let outlineAttributed = NSMutableAttributedString(attributedString: attributed)
            outlineAttributed.addAttribute(.foregroundColor, value: style.outlineColor.cgColor, range: NSRange(location: 0, length: outlineAttributed.length))
            drawOutlinedText(outlineAttributed, in: textRect, context: context, radius: outline)
        }

        context.setShadow(offset: CGSize(width: 0, height: -max(1, shadow * 0.35)), blur: shadow, color: style.shadowColor.cgColor)
        draw(attributed, in: textRect, context: context)
        context.setShadow(offset: .zero, blur: 0, color: nil)

        guard let baseImage = context.makeImage() else { return nil }
        return transformedImage(
            baseImage,
            scaleX: style.scaleX,
            scaleY: style.scaleY,
            rotationDegrees: style.rotationDegrees
        )
    }

    private static func transformedImage(
        _ image: CGImage,
        scaleX rawScaleX: Double,
        scaleY rawScaleY: Double,
        rotationDegrees: Double
    ) -> CGImage? {
        let scaleX = CGFloat(max(0.05, min(10, rawScaleX)))
        let scaleY = CGFloat(max(0.05, min(10, rawScaleY)))
        let radians = CGFloat(rotationDegrees * .pi / 180)

        guard abs(scaleX - 1) > 0.0001 || abs(scaleY - 1) > 0.0001 || abs(radians) > 0.0001 else {
            return image
        }

        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        let scaledWidth = sourceWidth * scaleX
        let scaledHeight = sourceHeight * scaleY
        let cosine = abs(cos(radians))
        let sine = abs(sin(radians))
        let outputWidth = max(1, Int(ceil(scaledWidth * cosine + scaledHeight * sine)))
        let outputHeight = max(1, Int(ceil(scaledWidth * sine + scaledHeight * cosine)))

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
        context.translateBy(x: CGFloat(outputWidth) / 2, y: CGFloat(outputHeight) / 2)
        context.rotate(by: radians)
        context.scaleBy(x: scaleX, y: scaleY)
        context.draw(
            image,
            in: CGRect(
                x: -sourceWidth / 2,
                y: -sourceHeight / 2,
                width: sourceWidth,
                height: sourceHeight
            )
        )
        return context.makeImage()
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
