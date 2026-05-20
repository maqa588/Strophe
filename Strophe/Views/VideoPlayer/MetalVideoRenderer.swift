import SwiftUI
import MetalKit
import Metal
import CoreVideo

// MARK: - MetalVideoRenderer
// High-performance MTKView subclass rendering bi-planar NV12 (YCbCr 4:2:0) pixel buffers on the GPU.
final class MetalVideoRenderer: MTKView {
    private var textureCache: CVMetalTextureCache?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    
    private var currentPixelBuffer: CVPixelBuffer?
    private var lastPixelFormat: OSType = 0
    private let lock = NSLock()
    private var frameCount: Int = 0
    
    // Vertex data representing a full screen quad
    private struct Vertex {
        var position: SIMD4<Float>
        var texCoords: SIMD2<Float>
    }
    
    private let vertices: [Vertex] = [
        Vertex(position: SIMD4<Float>(-1.0, -1.0, 0.0, 1.0), texCoords: SIMD2<Float>(0.0, 1.0)),
        Vertex(position: SIMD4<Float>( 1.0, -1.0, 0.0, 1.0), texCoords: SIMD2<Float>(1.0, 1.0)),
        Vertex(position: SIMD4<Float>(-1.0,  1.0, 0.0, 1.0), texCoords: SIMD2<Float>(0.0, 0.0)),
        Vertex(position: SIMD4<Float>( 1.0,  1.0, 0.0, 1.0), texCoords: SIMD2<Float>(1.0, 0.0))
    ]
    
    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device ?? MTLCreateSystemDefaultDevice())
        setupMetal()
    }
    
    required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = MTLCreateSystemDefaultDevice()
        setupMetal()
    }
    
    private func setupMetal() {
        guard let device = self.device else { return }
        
        self.framebufferOnly = true
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.enableSetNeedsDisplay = true
        self.isPaused = true
        self.preferredFramesPerSecond = 0
        
        self.commandQueue = device.makeCommandQueue()
        
        // Shader source performing hardware-accelerated BT.709 color conversion from bi-planar NV12 YCbCr to Linear RGB.
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn  { float4 position [[attribute(0)]]; float2 texCoords [[attribute(1)]]; };
        struct VertexOut { float4 position [[position]];     float2 texCoords; };

        vertex VertexOut vertexShader(const device VertexIn* v [[buffer(0)]], uint vid [[vertex_id]]) {
            VertexOut out;
            out.position  = v[vid].position;
            out.texCoords = v[vid].texCoords;
            return out;
        }

        // BT.709 YCbCr (video range: Y 16-235, CbCr 16-240) → linear RGB
        fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                       texture2d<float> yTex  [[texture(0)]],
                                       texture2d<float> uvTex [[texture(1)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            float  y  = yTex.sample(s,  in.texCoords).r;
            float2 uv = uvTex.sample(s, in.texCoords).rg;

            constexpr float y_bias  = 16.0  / 255.0;
            constexpr float y_scale = 255.0 / 219.0;
            constexpr float uv_bias  = 128.0 / 255.0;
            constexpr float uv_scale = 255.0 / 224.0;
            y  = (y  - y_bias)  * y_scale;
            uv = (uv - uv_bias) * uv_scale;

            float r = y + 1.5748 * uv.y;
            float g = y - 0.1873 * uv.x - 0.4681 * uv.y;
            float b = y + 1.8556 * uv.x;

            return float4(clamp(float3(r, g, b), 0.0, 1.0), 1.0);
        }
        """
        
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexShader")
            pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentShader")
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            
            vertexBuffer = device.makeBuffer(bytes: vertices,
                                            length: vertices.count * MemoryLayout<Vertex>.stride,
                                            options: [])
            
            let cacheAttrs = [
                kCVMetalTextureCacheMaximumTextureAgeKey: 0
            ] as CFDictionary
            CVMetalTextureCacheCreate(kCFAllocatorDefault, cacheAttrs, device, nil, &textureCache)
        } catch {
            print("❌ MetalVideoRenderer: Failed to setup pipeline: \(error)")
        }
    }
    
    // Queue a new bi-planar NV12 pixel buffer for immediate rendering
    func update(with pixelBuffer: CVPixelBuffer) {
        lock.lock()
        self.currentPixelBuffer = pixelBuffer
        lock.unlock()
        
        if Thread.isMainThread {
            self.draw()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.draw()
            }
        }
    }
    
    override func draw(_ rect: CGRect) {
        autoreleasepool {
            self._draw(rect)
        }
    }
    
    private func _draw(_ rect: CGRect) {
        lock.lock()
        guard let pixelBuffer = currentPixelBuffer else {
            lock.unlock()
            print("❌ draw: no pixelBuffer")
            return
        }
        guard let cache = textureCache else {
            lock.unlock()
            print("❌ draw: no textureCache")
            return
        }
        guard let pipeline = pipelineState else {
            lock.unlock()
            print("❌ draw: no pipelineState")
            return
        }
        guard let vBuffer = vertexBuffer else {
            lock.unlock()
            print("❌ draw: no vertexBuffer")
            return
        }
        guard let cmdQueue = commandQueue else {
            lock.unlock()
            print("❌ draw: no commandQueue")
            return
        }
        guard let renderPass = currentRenderPassDescriptor else {
            lock.unlock()
            print("❌ draw: no currentRenderPassDescriptor")
            return
        }
        guard let drawable = currentDrawable else {
            lock.unlock()
            print("❌ draw: no currentDrawable")
            return
        }
        

        
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        if pixelFormat != lastPixelFormat {
            lastPixelFormat = pixelFormat
            let bytes = [
                UInt8((pixelFormat >> 24) & 0xff),
                UInt8((pixelFormat >> 16) & 0xff),
                UInt8((pixelFormat >> 8) & 0xff),
                UInt8(pixelFormat & 0xff)
            ]
            let formatStr = String(bytes: bytes, encoding: .ascii) ?? String(pixelFormat)
            print("🎬 Video Format Changed: \(formatStr.trimmingCharacters(in: .controlCharacters)) (\(pixelFormat)), Size: \(width)x\(height)")
        }

        let is10Bit = (pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                       pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)

        let yMtlFormat: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
        let uvMtlFormat: MTLPixelFormat = is10Bit ? .rg16Unorm : .rg8Unorm

        // plane 0: Y
        var cvY: CVMetalTexture?
        _ = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            yMtlFormat, width, height, 0, &cvY)

        // plane 1: CbCr
        var cvUV: CVMetalTexture?
        _ = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            uvMtlFormat, width / 2, height / 2, 1, &cvUV)

        guard let yTex  = cvY.flatMap(CVMetalTextureGetTexture),
              let uvTex = cvUV.flatMap(CVMetalTextureGetTexture) else {
            lock.unlock()
            print("❌ draw: failed to create textures from YUV planes. Y: \(cvY != nil), UV: \(cvUV != nil)")
            return
        }
        lock.unlock()

        guard let cmdBuffer = cmdQueue.makeCommandBuffer(),
              let encoder   = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            print("❌ draw: failed to make command buffer or encoder")
            return
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(yTex,  index: 0)
        encoder.setFragmentTexture(uvTex, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        cmdBuffer.present(drawable)
        cmdBuffer.commit()
        
        frameCount += 1
        if frameCount % 60 == 0 {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
}

#if os(macOS)
struct MetalPlayerViewRepresentable: NSViewRepresentable {
    let renderer: MetalVideoRenderer
    
    init(renderer: MetalVideoRenderer) {
        self.renderer = renderer
    }
    
    func makeNSView(context: Context) -> NSView {
        return renderer
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#else
struct MetalPlayerViewRepresentable: UIViewRepresentable {
    let renderer: MetalVideoRenderer
    
    init(renderer: MetalVideoRenderer) {
        self.renderer = renderer
    }
    
    func makeUIView(context: Context) -> UIView {
        return renderer
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
