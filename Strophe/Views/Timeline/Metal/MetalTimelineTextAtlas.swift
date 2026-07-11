import CoreText
import MetalKit
import SwiftUI

@MainActor
final class MetalTimelineTextAtlas {
    struct Entry {
        var uvRect: SIMD4<Float>
        var pointSize: SIMD2<Float>
    }

    let texture: MTLTexture
    private let atlasSize = 2048
    private let displayScale: CGFloat
    private let padding = 2
    private var cursorX = 2
    private var cursorY = 2
    private var rowHeight = 0
    private var entries: [String: Entry] = [:]

    init?(device: MTLDevice, displayScale: CGFloat) {
        self.displayScale = displayScale
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: atlasSize,
            height: atlasSize,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
    }

    func prepareEntries(for strings: [String]) -> [String: Entry] {
        let uniqueStrings = Array(Set(strings))
        var result: [String: Entry] = [:]
        result.reserveCapacity(uniqueStrings.count)

        for string in uniqueStrings {
            if let cached = entries[string] {
                result[string] = cached
                continue
            }
            guard let entry = insert(string) else {
                reset()
                return prepareCurrentFrame(uniqueStrings)
            }
            result[string] = entry
        }
        return result
    }

    private func prepareCurrentFrame(_ strings: [String]) -> [String: Entry] {
        var result: [String: Entry] = [:]
        for string in strings {
            guard let entry = insert(string) else { continue }
            result[string] = entry
        }
        return result
    }

    private func insert(_ string: String) -> Entry? {
        guard let bitmap = renderBitmap(string) else { return nil }
        let width = bitmap.width
        let height = bitmap.height
        guard width + padding * 2 <= atlasSize, height + padding * 2 <= atlasSize else { return nil }

        if cursorX + width + padding > atlasSize {
            cursorX = padding
            cursorY += rowHeight + padding
            rowHeight = 0
        }
        guard cursorY + height + padding <= atlasSize else { return nil }

        bitmap.pixels.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(cursorX, cursorY, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: width
            )
        }

        let size = Float(atlasSize)
        let entry = Entry(
            uvRect: SIMD4<Float>(
                Float(cursorX) / size,
                Float(cursorY) / size,
                Float(cursorX + width) / size,
                Float(cursorY + height) / size
            ),
            pointSize: SIMD2<Float>(
                Float(CGFloat(width) / displayScale),
                Float(CGFloat(height) / displayScale)
            )
        )
        entries[string] = entry
        cursorX += width + padding
        rowHeight = max(rowHeight, height)
        return entry
    }

    private func reset() {
        entries.removeAll(keepingCapacity: true)
        cursorX = padding
        cursorY = padding
        rowHeight = 0
    }

    private func renderBitmap(_ string: String) -> (pixels: [UInt8], width: Int, height: Int)? {
        let fontSize = 11.5 * displayScale
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let typographicWidth = CGFloat(
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        )

        let width = min(atlasSize - padding * 2, max(1, Int(ceil(typographicWidth)) + 2))
        let height = max(1, Int(ceil(ascent + descent + leading)) + 2)
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 1, y: descent + 1)
            CTLineDraw(line, context)
            return true
        }
        return rendered ? (pixels, width, height) : nil
    }
}

nonisolated extension CGRect {
    var simdRect: SIMD4<Float> {
        SIMD4<Float>(Float(minX), Float(minY), Float(width), Float(height))
    }
}

nonisolated extension ResolvedRGBAColor {
    var simdColor: SIMD4<Float> {
        SIMD4<Float>(Float(red), Float(green), Float(blue), Float(alpha))
    }
}
