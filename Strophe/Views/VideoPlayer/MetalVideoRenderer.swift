import SwiftUI
import MetalKit
import Metal
import CoreVideo
import simd

// MARK: - MetalVideoRenderer
// High-performance MTKView subclass rendering bi-planar NV12 (YCbCr 4:2:0) pixel buffers on the GPU.
final class MetalVideoRenderer: MTKView {
    private var textureCache: CVMetalTextureCache?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    
    private var currentPixelBuffer: CVPixelBuffer?
    private var lastPixelFormat: OSType = 0
    private var lastColorMatrix: CFString? = nil
    private var lastColorProfile: VideoColorProfile = .sdr709
    private let lock = NSLock()
    
    // CPU-GPU 共享的转换矩阵结构体（严格保持 16 字节对齐）
    private struct ColorConversion {
        var matrix: simd_float3x3  // 48 字节 (每列 16 字节对齐)
        var offset: simd_float4    // 16 字节 (使用 float4 代替 float3 避免内存对齐对不上的问题)
    }
    
    // BT.709 转换矩阵
    private let bt709Conversion = ColorConversion(
        matrix: simd_float3x3(
            simd_float3(1.16438356, 1.16438356, 1.16438356),
            simd_float3(0.0, -0.2132209, 2.1124017),
            simd_float3(1.7927411, -0.5328817, 0.0)
        ),
        offset: simd_float4(-16.0 / 255.0, -128.0 / 255.0, -128.0 / 255.0, 0.0)
    )

    // BT.2020 转换矩阵 (广色域)
    private let bt2020Conversion = ColorConversion(
        matrix: simd_float3x3(
            simd_float3(1.16438356, 1.16438356, 1.16438356),
            simd_float3(0.0, -0.187326, 2.14177),
            simd_float3(1.67867, -0.6504, 0.0)
        ),
        offset: simd_float4(-16.0 / 255.0, -128.0 / 255.0, -128.0 / 255.0, 0.0)
    )

    // BT.601 转换矩阵 (老旧/标清视频兼容)
    private let bt601Conversion = ColorConversion(
        matrix: simd_float3x3(
            simd_float3(1.16438356, 1.16438356, 1.16438356),
            simd_float3(0.0, -0.39173, 2.017),
            simd_float3(1.5958, -0.8129, 0.0)
        ),
        offset: simd_float4(-16.0 / 255.0, -128.0 / 255.0, -128.0 / 255.0, 0.0)
    )

    // P010 uses video-range code values 64...940 / 64...960 rather than
    // the 8-bit 16...235 / 16...240 ranges used by NV12.
    private let bt70910BitConversion = ColorConversion(
        matrix: simd_float3x3(
            simd_float3(1.1678082, 1.1678082, 1.1678082),
            simd_float3(0.0, -0.214082, 2.118614),
            simd_float3(1.798013, -0.534477, 0.0)
        ),
        offset: simd_float4(-64.0 / 1023.0, -512.0 / 1023.0, -512.0 / 1023.0, 0.0)
    )

    private let bt202010BitConversion = ColorConversion(
        matrix: simd_float3x3(
            simd_float3(1.1678082, 1.1678082, 1.1678082),
            simd_float3(0.0, -0.187877, 2.148072),
            simd_float3(1.683611, -0.652337, 0.0)
        ),
        offset: simd_float4(-64.0 / 1023.0, -512.0 / 1023.0, -512.0 / 1023.0, 0.0)
    )
    
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
        // Float output avoids quantizing 10-bit HDR before Core Animation's
        // PQ/HLG display transform and also preserves out-of-gamut excursions.
        self.colorPixelFormat = .rgba16Float
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.enableSetNeedsDisplay = true
        self.isPaused = true
        self.preferredFramesPerSecond = 0
        
        self.commandQueue = device.makeCommandQueue()
        
        // 动态支持 BT.601 / BT.709 / BT.2020 的矩阵转换着色器
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn  { float4 position [[attribute(0)]]; float2 texCoords [[attribute(1)]]; };
        struct VertexOut { float4 position [[position]];     float2 texCoords; };

        struct ColorConversion {
            float3x3 matrix;
            float4 offset;
        };

        vertex VertexOut vertexShader(const device VertexIn* v [[buffer(0)]], uint vid [[vertex_id]]) {
            VertexOut out;
            out.position  = v[vid].position;
            out.texCoords = v[vid].texCoords;
            return out;
        }

        fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                       texture2d<float> yTex  [[texture(0)]],
                                       texture2d<float> uvTex [[texture(1)]],
                                       constant ColorConversion &conversion [[buffer(0)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            float  y  = yTex.sample(s,  in.texCoords).r;
            float2 uv = uvTex.sample(s, in.texCoords).rg;

            // 归一化输入 YUV
            float3 yuv = float3(y, uv.x, uv.y);
            
            // 应用传入的色彩空间矩阵与偏移
            float3 rgb = conversion.matrix * (yuv + conversion.offset.xyz);

            return float4(max(rgb, float3(0.0)), 1.0);
        }
        """
        
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexShader")
            pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentShader")
            pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
            
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
    
    func update(with pixelBuffer: CVPixelBuffer) {
        lock.lock()
        self.currentPixelBuffer = pixelBuffer
        lock.unlock()
        
        if Thread.isMainThread {
            #if os(macOS)
            self.needsDisplay = true
            #else
            self.setNeedsDisplay()
            #endif
        } else {
            Task { @MainActor [weak self] in
                #if os(macOS)
                self?.needsDisplay = true
                #else
                self?.setNeedsDisplay()
                #endif
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
        let pixelBuffer = currentPixelBuffer
        lock.unlock()

        guard let pixelBuffer else { return }
        guard let cache = textureCache else {
            return
        }
        guard let pipeline = pipelineState else {
            return
        }
        guard let vBuffer = vertexBuffer else {
            return
        }
        guard let cmdQueue = commandQueue else {
            return
        }
        guard let renderPass = currentRenderPassDescriptor else {
            return
        }
        guard let drawable = currentDrawable else {
            return
        }
        
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // 1. 色彩空间检测与更新
        let colorMatrix = getYCbCrMatrix(from: pixelBuffer)
        let colorProfile = VideoColorProfile.detect(in: pixelBuffer)
        if colorMatrix != lastColorMatrix || colorProfile != lastColorProfile {
            lastColorMatrix = colorMatrix
            lastColorProfile = colorProfile
            updateLayerColorSpace(for: colorMatrix, profile: colorProfile)
        }

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
        let statusY = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            yMtlFormat, width, height, 0, &cvY)
        if statusY != kCVReturnSuccess {
            print("❌ CVMetalTextureCacheCreateTextureFromImage failed for Y plane: \(statusY)")
        }

        // plane 1: CbCr
        var cvUV: CVMetalTexture?
        let statusUV = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            uvMtlFormat, width / 2, height / 2, 1, &cvUV)
        if statusUV != kCVReturnSuccess {
            print("❌ CVMetalTextureCacheCreateTextureFromImage failed for UV plane: \(statusUV)")
        }

        guard let yTex  = cvY.flatMap(CVMetalTextureGetTexture),
              let uvTex = cvUV.flatMap(CVMetalTextureGetTexture) else {
            return
        }

        guard let cmdBuffer = cmdQueue.makeCommandBuffer(),
              let encoder   = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            return
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(yTex,  index: 0)
        encoder.setFragmentTexture(uvTex, index: 1)
        
        // 2. 选择对应的色彩空间转换矩阵，并安全传入着色器
        var activeConversion = colorConversion(
            for: colorMatrix,
            pixelFormat: pixelFormat,
            is10Bit: is10Bit
        )
        
        encoder.setFragmentBytes(&activeConversion, length: MemoryLayout<ColorConversion>.size, index: 0)
        
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        let wrappedY = SendableTextureWrapper(texture: cvY)
        let wrappedUV = SendableTextureWrapper(texture: cvUV)
        cmdBuffer.addCompletedHandler { _ in
            _ = wrappedY
            _ = wrappedUV
        }
        
        cmdBuffer.present(drawable)
        cmdBuffer.commit()
        
    }
    
    // 从 CVPixelBuffer 获取色彩空间元数据
        private func getYCbCrMatrix(from pixelBuffer: CVPixelBuffer) -> CFString {
            // macOS 12.0+ 推荐使用 CVBufferCopyAttachment 代替 CVBufferGetAttachment
            if let attachment = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil),
               let matrix = attachment as? String {
                return matrix as CFString
            }
            // 默认回退到 BT.709，Swift API 中它的宏常量后缀带有 _2
            return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
        
        // 动态更新 CAMetalLayer 的物理色彩空间，防止系统级色偏
        @MainActor
        private func updateLayerColorSpace(
            for matrix: CFString,
            profile: VideoColorProfile
        ) {
            let cgColorSpace: CGColorSpace

            if profile.isHDR {
                cgColorSpace = profile.outputColorSpace
                print("🎨 Metal Canvas Color Space: \(profile == .hdrPQ ? "HDR PQ" : "HDR HLG")")
            } else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 {
                // 正确的 Swift CoreGraphics 常量名为 CGColorSpace.itur_2020
                cgColorSpace = CGColorSpace(name: CGColorSpace.itur_2020) ?? CGColorSpaceCreateDeviceRGB()
                print("🎨 Metal Canvas Color Space: BT.2020 (ITU-R BT.2020)")
            } else {
                cgColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                print("🎨 Metal Canvas Color Space: sRGB/BT.709")
            }
            
            if let metalLayer = self.layer as? CAMetalLayer {
                metalLayer.colorspace = cgColorSpace
                metalLayer.wantsExtendedDynamicRangeContent = profile.isHDR
            }
        }

        private func colorConversion(
            for matrix: CFString,
            pixelFormat: OSType,
            is10Bit: Bool
        ) -> ColorConversion {
            let isFullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange

            if isFullRange {
                let offset = simd_float4(0, -0.5, -0.5, 0)
                if matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 {
                    return ColorConversion(
                        matrix: simd_float3x3(
                            simd_float3(1.0, 1.0, 1.0),
                            simd_float3(0.0, -0.164553, 1.8814),
                            simd_float3(1.4746, -0.571353, 0.0)
                        ),
                        offset: offset
                    )
                }
                return ColorConversion(
                    matrix: simd_float3x3(
                        simd_float3(1.0, 1.0, 1.0),
                        simd_float3(0.0, -0.187324, 1.8556),
                        simd_float3(1.5748, -0.468124, 0.0)
                    ),
                    offset: offset
                )
            }

            if is10Bit {
                return matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020
                    ? bt202010BitConversion
                    : bt70910BitConversion
            }
            if matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 {
                return bt2020Conversion
            }
            if matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 {
                return bt601Conversion
            }
            return bt709Conversion
        }
}

private struct SendableTextureWrapper: @unchecked Sendable {
    let texture: CVMetalTexture?
}
