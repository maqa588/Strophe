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

// 用于向 FFmpeg 声明优先选择 VideoToolbox 硬件像素格式
nonisolated(unsafe) let getFormatCallback: @convention(c) (UnsafeMutablePointer<AVCodecContext>?, UnsafePointer<AVPixelFormat>?) -> AVPixelFormat = { ctx, fmts in
    guard let fmts = fmts else { return AV_PIX_FMT_NONE }
    var i = 0
    while fmts[i] != AV_PIX_FMT_NONE {
        if fmts[i] == AV_PIX_FMT_VIDEOTOOLBOX {
            return AV_PIX_FMT_VIDEOTOOLBOX
        }
        i += 1
    }
    // 如果硬件不可用，降级使用列表中的第一个软件像素格式
    return fmts[0]
}
