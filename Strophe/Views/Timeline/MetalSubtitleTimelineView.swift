import CoreText
import MetalKit
import SwiftUI
import simd

nonisolated struct MetalTimelineBlockRenderData: Equatable, Sendable {
    var id: UUID
    var rect: CGRect
    var fillColor: ResolvedRGBAColor
    var strokeColor: ResolvedRGBAColor
    var textColor: ResolvedRGBAColor
    var markerColor: ResolvedRGBAColor
    var strokeWidth: CGFloat
    var isLocked: Bool
    var hasIndependentPresentation: Bool
    var text: String
    var isCompact: Bool
}

nonisolated struct MetalTimelineFrameRenderData: Equatable, Sendable {
    var viewportSize: CGSize
    var blocks: [MetalTimelineBlockRenderData]
    var overlapRects: [CGRect]
    var marqueeRect: CGRect?

    static let empty = MetalTimelineFrameRenderData(
        viewportSize: .zero,
        blocks: [],
        overlapRects: [],
        marqueeRect: nil
    )
}

struct MetalStaticSubtitleTimelineLayer: View, Equatable {
    let renderRevision: UInt64
    let items: [SubtitleItem]
    let groups: [SubGroupItem]
    let selectedIDs: Set<UUID>
    let excludedIDs: Set<UUID>
    let pixelsPerSecond: Double
    let visibleStartTime: Double
    let viewWidth: CGFloat
    let blockY: CGFloat
    let blockHeight: CGFloat
    let isCompact: Bool
    let colorScheme: ColorScheme

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.renderRevision == rhs.renderRevision
            && lhs.excludedIDs == rhs.excludedIDs
            && lhs.pixelsPerSecond == rhs.pixelsPerSecond
            && lhs.visibleStartTime == rhs.visibleStartTime
            && lhs.viewWidth == rhs.viewWidth
            && lhs.blockY == rhs.blockY
            && lhs.blockHeight == rhs.blockHeight
            && lhs.isCompact == rhs.isCompact
            && lhs.colorScheme == rhs.colorScheme
    }

    var body: some View {
        let viewportOriginX = CGFloat(visibleStartTime * pixelsPerSecond)
        let viewportSize = CGSize(width: viewWidth, height: blockY + blockHeight + 10)
        let blocks = items.compactMap { item -> MetalTimelineBlockRenderData? in
            guard !excludedIDs.contains(item.id), let start = item.startTime else { return nil }
            let end = item.endTime ?? (start + 0.1)
            return makeBlock(item: item, start: start, end: end, viewportOriginX: viewportOriginX)
        }

        MetalSubtitleTimelineView(
            renderData: MetalTimelineFrameRenderData(
                viewportSize: viewportSize,
                blocks: blocks,
                overlapRects: [],
                marqueeRect: nil
            )
        )
        .frame(width: viewWidth, height: viewportSize.height)
        .offset(x: viewportOriginX)
        .allowsHitTesting(false)
    }

    private func makeBlock(
        item: SubtitleItem,
        start: Double,
        end: Double,
        viewportOriginX: CGFloat
    ) -> MetalTimelineBlockRenderData {
        let group = group(for: item)
        let groupColor = (group?.color ?? Color.stropheBlue).resolvedRGBA
        let isSelected = selectedIDs.contains(item.id)
        let isLocked = item.isLocked || group?.isLocked == true
        let isDimmed = item.isHidden || group?.isOverlayEnabled == false
        let opacity = isDimmed ? 0.42 : 1.0
        let primary = colorScheme == .dark
            ? ResolvedRGBAColor(red: 0.94, green: 0.93, blue: 0.91, alpha: opacity)
            : ResolvedRGBAColor(red: 0.08, green: 0.08, blue: 0.08, alpha: opacity)

        return MetalTimelineBlockRenderData(
            id: item.id,
            rect: CGRect(
                x: CGFloat(start * pixelsPerSecond) - viewportOriginX,
                y: blockY,
                width: max(4, CGFloat((end - start) * pixelsPerSecond)),
                height: blockHeight
            ),
            fillColor: groupColor.withAlpha((isSelected ? 0.62 : 0.28) * opacity),
            strokeColor: (isSelected ? Color.yellow.resolvedRGBA : groupColor).withAlpha(opacity),
            textColor: isSelected ? .white.withAlpha(opacity) : primary,
            markerColor: isSelected ? .white.withAlpha(opacity) : groupColor.withAlpha(opacity),
            strokeWidth: isSelected ? 2 : 1,
            isLocked: isLocked,
            hasIndependentPresentation: item.hasIndependentPresentation,
            text: item.text,
            isCompact: isCompact
        )
    }

    private func group(for item: SubtitleItem) -> SubGroupItem? {
        groups.first(where: { $0.id == item.groupID })
            ?? groups.first(where: \.isActive)
            ?? groups.first
    }
}

#if os(macOS)
struct MetalSubtitleTimelineView: NSViewRepresentable {
    let renderData: MetalTimelineFrameRenderData

    func makeNSView(context: Context) -> MetalSubtitleTimelineRenderer {
        MetalSubtitleTimelineRenderer()
    }

    func updateNSView(_ view: MetalSubtitleTimelineRenderer, context: Context) {
        view.update(renderData: renderData)
    }
}
#else
struct MetalSubtitleTimelineView: UIViewRepresentable {
    let renderData: MetalTimelineFrameRenderData

    func makeUIView(context: Context) -> MetalSubtitleTimelineRenderer {
        MetalSubtitleTimelineRenderer()
    }

    func updateUIView(_ view: MetalSubtitleTimelineRenderer, context: Context) {
        view.update(renderData: renderData)
    }
}
#endif

@MainActor
final class MetalSubtitleTimelineRenderer: MTKView {
    private struct GPUPrimitive {
        var rect: SIMD4<Float>
        var fillColor: SIMD4<Float>
        var strokeColor: SIMD4<Float>
        var auxiliaryColor: SIMD4<Float>
        /// x: corner radius, y: stroke width, z: mode, w: flags
        var parameters: SIMD4<Float>
    }

    private struct GPUText {
        var rect: SIMD4<Float>
        var uvRect: SIMD4<Float>
        var clipRect: SIMD4<Float>
        var color: SIMD4<Float>
    }

    private enum PrimitiveMode: Float {
        case block = 0
        case overlap = 1
        case marquee = 2
    }

    private var commandQueue: MTLCommandQueue?
    private var primitivePipeline: MTLRenderPipelineState?
    private var textPipeline: MTLRenderPipelineState?
    private var textAtlas: MetalTimelineTextAtlas?
    private var textAtlasScale: CGFloat = 0
    private var renderData: MetalTimelineFrameRenderData = .empty

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        configureMetal()
    }

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device ?? MTLCreateSystemDefaultDevice())
        configureMetal()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        device = MTLCreateSystemDefaultDevice()
        configureMetal()
    }

    func update(renderData newValue: MetalTimelineFrameRenderData) {
        guard renderData != newValue else { return }
        renderData = newValue
        requestDisplay()
    }

    private func configureMetal() {
        guard let device else { return }

        framebufferOnly = true
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        enableSetNeedsDisplay = true
        isPaused = true
        autoResizeDrawable = true
        preferredFramesPerSecond = 120

        #if os(macOS)
        wantsLayer = true
        layer?.isOpaque = false
        #else
        isOpaque = false
        backgroundColor = .clear
        #endif

        commandQueue = device.makeCommandQueue()
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            primitivePipeline = try makePipeline(
                device: device,
                library: library,
                vertex: "timelinePrimitiveVertex",
                fragment: "timelinePrimitiveFragment"
            )
            textPipeline = try makePipeline(
                device: device,
                library: library,
                vertex: "timelineTextVertex",
                fragment: "timelineTextFragment"
            )
        } catch {
            print("❌ MetalSubtitleTimelineRenderer pipeline setup failed: \(error)")
        }
    }

    private func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertex: String,
        fragment: String
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func requestDisplay() {
        #if os(macOS)
        needsDisplay = true
        #else
        setNeedsDisplay()
        #endif
    }

    override func draw(_ rect: CGRect) {
        autoreleasepool {
            drawFrame()
        }
    }

    private func drawFrame() {
        guard renderData.viewportSize.width > 0, renderData.viewportSize.height > 0,
              let device,
              let commandQueue,
              let primitivePipeline,
              let textPipeline,
              let renderPass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            return
        }

        var viewportSize = SIMD2<Float>(
            Float(renderData.viewportSize.width),
            Float(renderData.viewportSize.height)
        )
        encodePrimitives(
            makeBlockPrimitives(),
            device: device,
            encoder: encoder,
            pipeline: primitivePipeline,
            viewportSize: &viewportSize
        )

        if renderData.blocks.contains(where: { !$0.isCompact && !$0.text.isEmpty }) {
            let logicalWidth = max(1, bounds.width)
            let requestedAtlasScale = min(3, max(1, drawableSize.width / logicalWidth))
            if textAtlas == nil || abs(textAtlasScale - requestedAtlasScale) > 0.1 {
                textAtlasScale = requestedAtlasScale
                textAtlas = MetalTimelineTextAtlas(device: device, displayScale: requestedAtlasScale)
            }
        }

        if let textAtlas {
            let textInstances = makeTextInstances(atlas: textAtlas)
            if !textInstances.isEmpty,
               let buffer = device.makeBuffer(
                   bytes: textInstances,
                   length: textInstances.count * MemoryLayout<GPUText>.stride,
                   options: .storageModeShared
               ) {
                encoder.setRenderPipelineState(textPipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&viewportSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                encoder.setFragmentTexture(textAtlas.texture, index: 0)
                encoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: 6,
                    instanceCount: textInstances.count
                )
            }
        }

        // Diagnostics and the marquee must remain visually above both block fills
        // and cached text, matching the previous timeline behavior.
        encodePrimitives(
            makeOverlayPrimitives(),
            device: device,
            encoder: encoder,
            pipeline: primitivePipeline,
            viewportSize: &viewportSize
        )

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func encodePrimitives(
        _ primitives: [GPUPrimitive],
        device: MTLDevice,
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        viewportSize: inout SIMD2<Float>
    ) {
        guard !primitives.isEmpty,
              let buffer = device.makeBuffer(
                  bytes: primitives,
                  length: primitives.count * MemoryLayout<GPUPrimitive>.stride,
                  options: .storageModeShared
              ) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&viewportSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: primitives.count
        )
    }

    private func makeBlockPrimitives() -> [GPUPrimitive] {
        var result: [GPUPrimitive] = []
        result.reserveCapacity(renderData.blocks.count)

        for block in renderData.blocks {
            var flags: Float = 0
            if block.hasIndependentPresentation { flags += 1 }
            if block.isLocked { flags += 2 }
            result.append(
                GPUPrimitive(
                    rect: block.rect.simdRect,
                    fillColor: block.fillColor.simdColor,
                    strokeColor: block.strokeColor.simdColor,
                    auxiliaryColor: block.markerColor.simdColor,
                    parameters: SIMD4<Float>(
                        4,
                        Float(block.strokeWidth),
                        PrimitiveMode.block.rawValue,
                        flags
                    )
                )
            )
        }

        return result
    }

    private func makeOverlayPrimitives() -> [GPUPrimitive] {
        var result: [GPUPrimitive] = []
        result.reserveCapacity(renderData.overlapRects.count + (renderData.marqueeRect == nil ? 0 : 1))

        let overlapFill = ResolvedRGBAColor(red: 1, green: 0.08, blue: 0.55, alpha: 0.15)
        let overlapStroke = ResolvedRGBAColor(red: 1, green: 0.08, blue: 0.55, alpha: 0.8)
        for rect in renderData.overlapRects {
            result.append(
                GPUPrimitive(
                    rect: rect.simdRect,
                    fillColor: overlapFill.simdColor,
                    strokeColor: overlapStroke.simdColor,
                    auxiliaryColor: overlapStroke.withAlpha(0.6).simdColor,
                    parameters: SIMD4<Float>(4, 1, PrimitiveMode.overlap.rawValue, 0)
                )
            )
        }

        if let rect = renderData.marqueeRect {
            let blue = Color.stropheBlue.resolvedRGBA
            result.append(
                GPUPrimitive(
                    rect: rect.simdRect,
                    fillColor: blue.withAlpha(0.15).simdColor,
                    strokeColor: blue.simdColor,
                    auxiliaryColor: blue.simdColor,
                    parameters: SIMD4<Float>(0, 1.5, PrimitiveMode.marquee.rawValue, 0)
                )
            )
        }

        return result
    }

    private func makeTextInstances(atlas: MetalTimelineTextAtlas) -> [GPUText] {
        let textBlocks = renderData.blocks.filter {
            !$0.isCompact && $0.rect.width >= 14 && !$0.text.isEmpty
        }
        guard !textBlocks.isEmpty else { return [] }

        let entries = atlas.prepareEntries(for: textBlocks.map(\.text))
        var result: [GPUText] = []
        result.reserveCapacity(textBlocks.count)

        for block in textBlocks {
            guard let entry = entries[block.text] else { continue }
            let leadingInset: CGFloat = block.hasIndependentPresentation ? 18 : 8
            let trailingInset: CGFloat = block.isLocked ? 18 : 6
            let availableWidth = block.rect.width - leadingInset - trailingInset
            guard availableWidth > 3 else { continue }

            let rect = CGRect(
                x: block.rect.minX + leadingInset,
                y: block.rect.midY - CGFloat(entry.pointSize.y) * 0.5,
                width: CGFloat(entry.pointSize.x),
                height: CGFloat(entry.pointSize.y)
            )
            let clip = CGRect(
                x: block.rect.minX + leadingInset,
                y: block.rect.minY,
                width: availableWidth,
                height: block.rect.height
            )
            result.append(
                GPUText(
                    rect: rect.simdRect,
                    uvRect: entry.uvRect,
                    clipRect: clip.simdRect,
                    color: block.textColor.simdColor
                )
            )
        }
        return result
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct GPUPrimitive {
        float4 rect;
        float4 fillColor;
        float4 strokeColor;
        float4 auxiliaryColor;
        float4 parameters;
    };

    struct PrimitiveVertexOut {
        float4 position [[position]];
        float2 local;
        float2 size;
        float4 fillColor [[flat]];
        float4 strokeColor [[flat]];
        float4 auxiliaryColor [[flat]];
        float4 parameters [[flat]];
    };

    float2 timelineCorner(uint vertexID) {
        constexpr float2 corners[6] = {
            float2(0, 0), float2(1, 0), float2(0, 1),
            float2(0, 1), float2(1, 0), float2(1, 1)
        };
        return corners[vertexID];
    }

    vertex PrimitiveVertexOut timelinePrimitiveVertex(
        const device GPUPrimitive *instances [[buffer(0)]],
        constant float2 &viewportSize [[buffer(1)]],
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]]
    ) {
        GPUPrimitive primitive = instances[instanceID];
        float2 corner = timelineCorner(vertexID);
        float2 pixel = primitive.rect.xy + corner * primitive.rect.zw;

        PrimitiveVertexOut out;
        out.position = float4(
            pixel.x / viewportSize.x * 2.0 - 1.0,
            1.0 - pixel.y / viewportSize.y * 2.0,
            0,
            1
        );
        out.local = corner * primitive.rect.zw;
        out.size = primitive.rect.zw;
        out.fillColor = primitive.fillColor;
        out.strokeColor = primitive.strokeColor;
        out.auxiliaryColor = primitive.auxiliaryColor;
        out.parameters = primitive.parameters;
        return out;
    }

    float roundedBoxDistance(float2 local, float2 size, float radius) {
        float2 centered = local - size * 0.5;
        float2 q = abs(centered) - (size * 0.5 - radius);
        return length(max(q, float2(0))) + min(max(q.x, q.y), 0.0) - radius;
    }

    fragment float4 timelinePrimitiveFragment(PrimitiveVertexOut in [[stage_in]]) {
        float radius = min(in.parameters.x, min(in.size.x, in.size.y) * 0.5);
        float strokeWidth = in.parameters.y;
        int mode = int(round(in.parameters.z));
        int flags = int(round(in.parameters.w));

        float distance = roundedBoxDistance(in.local, in.size, radius);
        float aa = max(fwidth(distance), 0.65);
        float coverage = 1.0 - smoothstep(-aa, aa, distance);
        float border = coverage * (1.0 - smoothstep(strokeWidth - aa, strokeWidth + aa, -distance));

        if (mode == 1) {
            float stripePhase = fmod(in.local.x - in.local.y + 1024.0, 8.0);
            float stripe = (1.0 - smoothstep(1.2, 2.0, stripePhase)) * coverage;
            float4 color = mix(in.fillColor, in.auxiliaryColor, stripe * in.auxiliaryColor.a);
            color = mix(color, in.strokeColor, border);
            color.a *= coverage;
            return color;
        }

        if (mode == 2) {
            float dash = step(fmod(in.local.x + in.local.y, 8.0), 4.0);
            float4 color = mix(in.fillColor, in.strokeColor, border * dash);
            color.a *= coverage;
            return color;
        }

        if ((flags & 2) != 0) {
            float dash = step(fmod(in.local.x + in.local.y, 7.0), 4.0);
            border *= dash;
        }

        float4 color = mix(in.fillColor, in.strokeColor, border);

        if ((flags & 1) != 0 && in.size.x >= 24.0) {
            float markerDistance = length(in.local - float2(10.5, in.size.y * 0.5)) - 2.5;
            float marker = 1.0 - smoothstep(-aa, aa, markerDistance);
            color = mix(color, in.auxiliaryColor, marker);
        }

        if ((flags & 2) != 0 && in.size.x >= 28.0) {
            float2 lockLocal = in.local - float2(in.size.x - 11.0, in.size.y * 0.5);
            float body = step(abs(lockLocal.x), 3.5) * step(abs(lockLocal.y - 1.5), 3.0);
            float shackleOuter = 1.0 - smoothstep(0.7, 1.4, abs(length(float2(lockLocal.x, lockLocal.y + 2.0)) - 3.0));
            float shackle = shackleOuter * step(lockLocal.y, 0.0);
            float lockMask = saturate(body + shackle);
            color = mix(color, in.strokeColor, lockMask);
        }

        color.a *= coverage;
        return color;
    }

    struct GPUText {
        float4 rect;
        float4 uvRect;
        float4 clipRect;
        float4 color;
    };

    struct TextVertexOut {
        float4 position [[position]];
        float2 uv;
        float2 pixelPosition;
        float4 clipRect [[flat]];
        float4 color [[flat]];
    };

    vertex TextVertexOut timelineTextVertex(
        const device GPUText *instances [[buffer(0)]],
        constant float2 &viewportSize [[buffer(1)]],
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]]
    ) {
        GPUText text = instances[instanceID];
        float2 corner = timelineCorner(vertexID);
        float2 pixel = text.rect.xy + corner * text.rect.zw;

        TextVertexOut out;
        out.position = float4(
            pixel.x / viewportSize.x * 2.0 - 1.0,
            1.0 - pixel.y / viewportSize.y * 2.0,
            0,
            1
        );
        out.uv = float2(
            mix(text.uvRect.x, text.uvRect.z, corner.x),
            mix(text.uvRect.y, text.uvRect.w, corner.y)
        );
        out.pixelPosition = pixel;
        out.clipRect = text.clipRect;
        out.color = text.color;
        return out;
    }

    fragment float4 timelineTextFragment(
        TextVertexOut in [[stage_in]],
        texture2d<float> atlas [[texture(0)]]
    ) {
        if (in.pixelPosition.x < in.clipRect.x ||
            in.pixelPosition.y < in.clipRect.y ||
            in.pixelPosition.x > in.clipRect.x + in.clipRect.z ||
            in.pixelPosition.y > in.clipRect.y + in.clipRect.w) {
            discard_fragment();
        }
        constexpr sampler atlasSampler(address::clamp_to_edge, filter::linear);
        float alpha = atlas.sample(atlasSampler, in.uv).r;
        return float4(in.color.rgb, in.color.a * alpha);
    }
    """
}

@MainActor
private final class MetalTimelineTextAtlas {
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

private nonisolated extension CGRect {
    var simdRect: SIMD4<Float> {
        SIMD4<Float>(Float(minX), Float(minY), Float(width), Float(height))
    }
}

private nonisolated extension ResolvedRGBAColor {
    var simdColor: SIMD4<Float> {
        SIMD4<Float>(Float(red), Float(green), Float(blue), Float(alpha))
    }
}
