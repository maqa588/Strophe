import Foundation
import CoreVideo
import QuartzCore
import Libavcodec
import Libavformat
import Libavutil
import Libswscale
import Libswresample

// MARK: - CVPixelBuffer Pool for software decode path
extension FFmpegDecoderCore {

    nonisolated func convertFrameToPixelBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width  = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        let frameProfile = VideoColorProfile(
            ffmpegTransferRawValue: Int32(frame.pointee.color_trc.rawValue)
        )
        let colorProfile = frameProfile.isHDR ? frameProfile : sourceColorProfile

        if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            if let pb = frame.pointee.data.3 {
                let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(pb).takeUnretainedValue()
                colorProfile.attachColorMetadata(
                    to: pixelBuffer,
                    copyingStaticHDRMetadataFrom: pixelBuffer
                )
                return pixelBuffer
            }
        }

        // Software conversion tasks are deliberately serialized. That keeps
        // frames ordered and lets libswscale reuse its filter/context state
        // instead of constructing and destroying it for every frame.
        softwareConversionLock.lock()
        defer { softwareConversionLock.unlock() }

        // Software decode path — use a CVPixelBufferPool to reuse buffers
        // instead of creating new ones every frame (prevents FPS degradation)
        let destinationPixelFormat = colorProfile.pixelFormat
        if pixelBufferPool == nil || poolWidth != width || poolHeight != height || poolPixelFormat != destinationPixelFormat {
            // (Re)create pool for current resolution
            pixelBufferPool = nil
            poolWidth = width
            poolHeight = height
            poolPixelFormat = destinationPixelFormat

            let poolAttrs: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: 3
            ]
            let bufferAttrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: destinationPixelFormat,
                kCVPixelBufferMetalCompatibilityKey: true
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                   poolAttrs as CFDictionary,
                                   bufferAttrs as CFDictionary,
                                   &pixelBufferPool)
        }
        let pool = pixelBufferPool

        var pixelBuffer: CVPixelBuffer?
        guard let pool = pool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let yPlane  = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let uvPlane = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }

        let yStride  = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)

        let srcFmt = AVPixelFormat(rawValue: frame.pointee.format)

        softwareSwsContext = sws_getCachedContext(
            softwareSwsContext,
            Int32(width), Int32(height), srcFmt,
            Int32(width), Int32(height), colorProfile.isHDR ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12,
            Int32(SWS_FAST_BILINEAR.rawValue), nil, nil, nil
        )
        guard let swsCtx = softwareSwsContext else { return nil }

        var dstData: [UnsafeMutablePointer<UInt8>?] = [
            yPlane.assumingMemoryBound(to: UInt8.self),
            uvPlane.assumingMemoryBound(to: UInt8.self),
            nil, nil
        ]
        var dstLinesize: [Int32] = [Int32(yStride), Int32(uvStride), 0, 0]

        _ = frame.withMemoryRebound(to: AVFrame.self, capacity: 1) { framePtr in
            let srcData = withUnsafePointer(to: &framePtr.pointee.data) {
                $0.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { $0 }
            }
            let srcLinesize = withUnsafePointer(to: &framePtr.pointee.linesize) {
                $0.withMemoryRebound(to: Int32.self, capacity: 8) { $0 }
            }
            return sws_scale(swsCtx, srcData, srcLinesize, 0, Int32(height), &dstData, &dstLinesize)
        }

        colorProfile.attachColorMetadata(to: pb)
        return pb
    }
}
