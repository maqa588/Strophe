//
//  HardSubtitleVideoExportSettings.swift
//  Strophe
//
//  Created by Antigravity on 2026/06/04.
//

import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import VideoToolbox

enum HardSubtitleVideoExportError: LocalizedError {
    case missingMedia
    case missingVideoTrack
    case unsupportedInput(String)
    case cannotCreateReader
    case cannotCreateWriter
    case cannotStartReading(String)
    case cannotStartWriting(String)
    case cancelled
    case writerFailed(String)
    case readerFailed(String)
    case audioMuxFailed(String)
    case ffmpegDecodeFailed(String)
    case hdrRequiresCompatibleCodec
    case hdrSourceRequired

    var errorDescription: String? {
        switch self {
        case .missingMedia:
            return String(localized: "the_current_project_has_no")
        case .missingVideoTrack:
            return String(localized: "the_current_media_has_no")
        case .unsupportedInput(let ext):
            return String(localized: "v1_hard_subtitle_container_unsupported_format \(ext.uppercased())")
        case .cannotCreateReader:
            return String(localized: "unable_to_create_avassetreader")
        case .cannotCreateWriter:
            return String(localized: "unable_to_create_avassetwriter")
        case .cannotStartReading(let message):
            return String(localized: "unable_to_start_video_read_format \(message)")
        case .cannotStartWriting(let message):
            return String(localized: "unable_to_start_video_write_format \(message)")
        case .cancelled:
            return String(localized: "hard_subtitle_export_cancelled")
        case .writerFailed(let message):
            return String(localized: "video_write_failed_format \(message)")
        case .readerFailed(let message):
            return String(localized: "video_read_failed_format \(message)")
        case .audioMuxFailed(let message):
            return String(localized: "audio_remux_failed_format \(message)")
        case .ffmpegDecodeFailed(let message):
            return String(localized: "ffmpeg_decode_failed_format \(message)")
        case .hdrRequiresCompatibleCodec:
            return String(localized: "HDR 导出需要使用 H.265 / HEVC 或 Apple ProRes。")
        case .hdrSourceRequired:
            return String(localized: "当前视频不是可识别的 PQ/HLG HDR 视频，无法开启 HDR 导出。")
        }
    }
}

enum HardSubtitleVideoCodec: String, CaseIterable, Identifiable, Sendable {
    case h264
    case h265
    case proRes422HQ
    case proRes422
    case proRes422LT
    case proRes422Proxy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .h265: return "H.265 / HEVC"
        case .proRes422HQ: return "Apple ProRes 422 HQ"
        case .proRes422: return "Apple ProRes 422"
        case .proRes422LT: return "Apple ProRes 422 LT"
        case .proRes422Proxy: return "Apple ProRes 422 Proxy"
        }
    }

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .h265: return .hevc
        case .proRes422HQ: return .proRes422HQ
        case .proRes422: return .proRes422
        case .proRes422LT: return .proRes422LT
        case .proRes422Proxy: return .proRes422Proxy
        }
    }

    var fileType: AVFileType {
        switch self {
        case .h264, .h265: return .mp4
        case .proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy: return .mov
        }
    }

    var contentType: UTType {
        switch self {
        case .h264, .h265: return .mpeg4Movie
        case .proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy: return .quickTimeMovie
        }
    }

    var fileExtension: String {
        switch self {
        case .h264, .h265: return "mp4"
        case .proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy: return "mov"
        }
    }
    
    var isProRes: Bool {
        switch self {
        case .proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy: return true
        default: return false
        }
    }

    var supportsHDR: Bool {
        self == .h265 || isProRes
    }

    func outputSettings(
        width: Int,
        height: Int,
        frameRate: Double,
        exportSettings: HardSubtitleVideoExportSettings,
        colorProfile: VideoColorProfile
    ) -> [String: Any] {
        #if os(macOS)
        let encoderSpecificationKey = AVVideoEncoderSpecificationKey
        let hardwareAccelerationKey = kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String
        #else
        // The iOS SDK does not expose these AVFoundation dictionary constants.
        let encoderSpecificationKey = "AVVideoEncoderSpecificationKey"
        let hardwareAccelerationKey = "EnableHardwareAcceleratedVideoEncoder"
        #endif

        var settings: [String: Any] = [
            AVVideoCodecKey: avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: colorProfile.avVideoColorProperties
        ]

        if exportSettings.usesSoftwareEncoding {
            // false explicitly prevents VideoToolbox from selecting hardware.
            settings[encoderSpecificationKey] = [hardwareAccelerationKey: false]
        } else if !isProRes {
            #if os(macOS)
            // Preserve the existing hardware-preferred macOS path.
            settings[encoderSpecificationKey] = [hardwareAccelerationKey: true]
            #endif
        }

        if !isProRes {
            let expectedFrameRate = Int(max(1, frameRate.rounded()))
            var compressionProperties: [String: Any] = [:]
            switch exportSettings.rateControlMode {
            case .constantQuality:
                if #available(macOS 27.0, iOS 27.0, *) {
                    compressionProperties[kVTCompressionPropertyKey_ConstantQualityFactor as String] = exportSettings.resolvedConstantQualityFactor
                } else {
                    // Earlier VideoToolbox versions expose fixed quantizer
                    // quality rather than the newer adaptive CQF control.
                    compressionProperties[kVTCompressionPropertyKey_Quality as String] = exportSettings.resolvedConstantQualityFactor
                }
            case .bitrate:
                compressionProperties[kVTCompressionPropertyKey_AverageBitRate as String] = exportSettings.resolvedTargetBitrate
            }
            compressionProperties[AVVideoExpectedSourceFrameRateKey] = expectedFrameRate
            compressionProperties[AVVideoAllowFrameReorderingKey] = true
            compressionProperties[kVTCompressionPropertyKey_AllowTemporalCompression as String] = true
            compressionProperties[kVTCompressionPropertyKey_RealTime as String] = false
            compressionProperties[AVVideoProfileLevelKey] = self == .h265
                ? ((colorProfile.isHDR
                    ? kVTProfileLevel_HEVC_Main10_AutoLevel
                    : kVTProfileLevel_HEVC_Main_AutoLevel) as String)
                : AVVideoProfileLevelH264HighAutoLevel
            if self == .h264 {
                compressionProperties[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
            }
            settings[AVVideoCompressionPropertiesKey] = compressionProperties
        }

        return settings
    }
}

enum HardSubtitleVideoRateControlMode: String, CaseIterable, Identifiable, Sendable {
    case constantQuality
    case bitrate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .constantQuality: return String(localized: "constant_quality_short")
        case .bitrate: return String(localized: "target_bitrate")
        }
    }
}

struct HardSubtitleVideoExportSettings: Sendable, Equatable {
    var codec: HardSubtitleVideoCodec = .h264
    var rateControlMode: HardSubtitleVideoRateControlMode = .constantQuality
    var constantQualityPercent: Double = 50
    var targetBitrateMbps: Double = 8.0
    /// Display aspect and clean aperture are always respected during export.
    var usesDisplayAspect: Bool { true }
    var usesSoftwareEncoding: Bool = false
    /// H.264/H.265 SDR exports use NV12 by default. Enable this only when a
    /// device, source, or Core Image pipeline has compatibility issues.
    var usesBGRACompatibilityPixelBuffers: Bool = false
    var usesMultiPassEncoding: Bool = false
    var exportsHDR: Bool = false

    var resolvedConstantQualityFactor: Double {
        min(max(constantQualityPercent, 0), 100) / 100.0
    }

    var resolvedTargetBitrate: Int {
        Int(min(max(targetBitrateMbps, 0.3), 200) * 1_000_000)
    }
}

struct VideoExportPlaceholderDocument: FileDocument {
    static nonisolated let readableContentTypes: [UTType] = [.movie]
    static nonisolated let writableContentTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie]

    init() {}

    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}
