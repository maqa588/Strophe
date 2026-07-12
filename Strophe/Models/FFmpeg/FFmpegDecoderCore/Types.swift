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
