import MetalKit
import SwiftUI
import simd

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
        case lane = 3
        case shadow = 4
    }

    private var commandQueue: MTLCommandQueue?
    private var primitivePipeline: MTLRenderPipelineState?
    private var textPipeline: MTLRenderPipelineState?
    private var textAtlas: MetalTimelineTextAtlas?
    private var textAtlasScale: CGFloat = 0
    private var renderData: MetalTimelineFrameRenderData = .empty
    private var lastDrawableLogicalSize: CGSize = .zero

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

    #if os(macOS)
    override func layout() {
        super.layout()
        synchronizeDrawableSize()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        synchronizeDrawableSize()
    }
    #endif

    private func synchronizeDrawableSize() {
        let logicalSize = bounds.size
        guard logicalSize.width > 0, logicalSize.height > 0,
              logicalSize != lastDrawableLogicalSize else { return }
        lastDrawableLogicalSize = logicalSize
        #if os(macOS)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        #else
        let scale = window?.screen.scale ?? UIScreen.main.scale
        #endif
        drawableSize = CGSize(width: logicalSize.width * scale, height: logicalSize.height * scale)
        requestDisplay()
    }

    override func draw(_ rect: CGRect) {
        autoreleasepool {
            drawFrame()
        }
    }

    private func drawFrame() {
        guard renderData.viewportSize.width > 0, renderData.viewportSize.height > 0,
              bounds.width > 0, bounds.height > 0,
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
            Float(bounds.width),
            Float(bounds.height)
        )
        encodePrimitives(
            makeLanePrimitives(),
            device: device,
            encoder: encoder,
            pipeline: primitivePipeline,
            viewportSize: &viewportSize
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
            if block.liftProgress > 0 {
                let progress = CGFloat(block.liftProgress)
                let shadowRect = block.rect
                    .insetBy(dx: -2.5 * progress, dy: -1.5 * progress)
                    .offsetBy(dx: 0, dy: 5 * progress)
                result.append(
                    GPUPrimitive(
                        rect: shadowRect.simdRect,
                        fillColor: SIMD4<Float>(0, 0, 0, 0.32 * block.liftProgress),
                        strokeColor: .zero,
                        auxiliaryColor: .zero,
                        parameters: SIMD4<Float>(6, 0, PrimitiveMode.shadow.rawValue, 0)
                    )
                )
            }
            var flags: Float = 0
            if block.hasIndependentPresentation { flags += 1 }
            if block.isLocked { flags += 2 }
            if block.showsTrimHandles { flags += 4 }
            result.append(
                GPUPrimitive(
                    rect: block.rect.simdRect,
                    fillColor: block.fillColor.simdColor,
                    strokeColor: block.strokeColor.simdColor,
                    auxiliaryColor: block.markerColor.simdColor,
                    parameters: SIMD4<Float>(
                        4,
                        Float(block.strokeWidth) + block.liftProgress,
                        PrimitiveMode.block.rawValue,
                        flags
                    )
                )
            )
        }

        return result
    }

    private func makeLanePrimitives() -> [GPUPrimitive] {
        renderData.lanes.map { lane in
            GPUPrimitive(
                rect: lane.rect.simdRect,
                fillColor: lane.fillColor.simdColor,
                strokeColor: lane.separatorColor.simdColor,
                auxiliaryColor: lane.separatorColor.simdColor,
                parameters: SIMD4<Float>(0, 1, PrimitiveMode.lane.rawValue, 0)
            )
        }
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
}
