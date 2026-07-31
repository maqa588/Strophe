import Foundation
import CoreVideo
import QuartzCore
import Libavcodec
import Libavformat
import Libavutil
import Libswscale
import Libswresample

// MARK: - VideoFrame
nonisolated struct VideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let pts: Double
    let generation: Int
}

// MARK: - SendablePixelBuffer
nonisolated struct SendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
    /// Seek generation stamp — used by FFmpegEngine to discard stale pre-seek callbacks.
    let generation: Int
}

enum FFmpegPlaybackTuning {
    #if os(iOS)
        nonisolated static let normalQueueCapacity = 6
        nonisolated static let highFPSQueueCapacity = 10
        nonisolated static let codecThreads = "4"
        nonisolated static let frameThreads = "1"
        nonisolated static let tileThreads = "2"
    #else
        nonisolated static let normalQueueCapacity = 16
        nonisolated static let highFPSQueueCapacity = 24
        nonisolated static let codecThreads = "0"
        nonisolated static let frameThreads = "0"
        nonisolated static let tileThreads = "0"
    #endif

    /// Keeps enough decoded video locally to absorb ordinary SMB latency while
    /// bounding memory use for large (especially 4K) frames.
    nonisolated static func queueCapacity(
        fps: Double,
        width: Int,
        height: Int,
        isRemote: Bool
    ) -> Int {
        let baseline = fps > 45 ? highFPSQueueCapacity : normalQueueCapacity
        guard isRemote else { return baseline }

        let bytesPerFrame = max(1, width * height * 3 / 2)
        let memoryBound = max(baseline, (128 * 1_024 * 1_024) / bytesPerFrame)
        let jitterTarget = max(baseline, Int((fps * 1.25).rounded(.up)))
        return min(32, memoryBound, jitterTarget)
    }
}

/// Selects VideoToolbox output when the decoder offers it, then falls back to software.
nonisolated func ffmpegVideoToolboxFormatCallback(
    _ codecContext: UnsafeMutablePointer<AVCodecContext>?,
    _ formats: UnsafePointer<AVPixelFormat>?
) -> AVPixelFormat {
    _ = codecContext
    guard let formats else { return AV_PIX_FMT_NONE }
    var index = 0
    while formats[index] != AV_PIX_FMT_NONE {
        if formats[index] == AV_PIX_FMT_VIDEOTOOLBOX {
            return AV_PIX_FMT_VIDEOTOOLBOX
        }
        index += 1
    }
    return formats[0]
}
