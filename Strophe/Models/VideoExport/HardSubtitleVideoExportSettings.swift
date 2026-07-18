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
        var settings: [String: Any] = [
            AVVideoCodecKey: avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: colorProfile.avVideoColorProperties
        ]

        if !isProRes {
            #if os(macOS)
            settings[AVVideoEncoderSpecificationKey] = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
            ]
            #endif

            let bitrate = exportSettings.resolvedBitrate(width: width, height: height, frameRate: frameRate)
            let expectedFrameRate = Int(max(1, frameRate.rounded()))
            let keyFrameIntervalDuration = exportSettings.keyFrameIntervalDuration
            var compressionProperties: [String: Any] = [:]
            compressionProperties[AVVideoAverageBitRateKey] = bitrate
            if !exportSettings.usesMultiPassEncoding {
                compressionProperties[AVVideoQualityKey] = exportSettings.resolvedEncoderQuality
            }
            compressionProperties[AVVideoExpectedSourceFrameRateKey] = expectedFrameRate
            compressionProperties[AVVideoAllowFrameReorderingKey] = true
            compressionProperties[AVVideoMaxKeyFrameIntervalKey] = Int(max(Double(expectedFrameRate), frameRate * keyFrameIntervalDuration))
            compressionProperties[kVTCompressionPropertyKey_AllowTemporalCompression as String] = true
            compressionProperties[kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration as String] = keyFrameIntervalDuration
            compressionProperties[kVTCompressionPropertyKey_MaxFrameDelayCount as String] = exportSettings.maxFrameDelayCount
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

enum HardSubtitleVideoQualityMode: String, CaseIterable, Identifiable, Sendable {
    case crfLike
    case bitrate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crfLike: return "类 CRF"
        case .bitrate: return "target_bitrate"
        }
    }
}

enum HardSubtitleVideoSpeedPreset: Int, CaseIterable, Identifiable, Sendable {
    case compact = 4
    case medium = 6
    case quality = 8

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .compact: return "更小"
        case .medium: return "中等"
        case .quality: return "更清晰"
        }
    }

    var bitrateMultiplier: Double {
        switch self {
        case .compact: return 0.82
        case .medium: return 1.0
        case .quality: return 1.22
        }
    }
}

struct HardSubtitleVideoExportSettings: Sendable, Equatable {
    var codec: HardSubtitleVideoCodec = .h264
    var qualityMode: HardSubtitleVideoQualityMode = .crfLike
    var crfLikeValue: Double = 28
    var targetBitrateMbps: Double = 8.0
    var speedPreset: HardSubtitleVideoSpeedPreset = .medium
    var usesDisplayAspect: Bool = true
    var usesExperimentalNV12PixelBuffers: Bool = false
    var usesMultiPassEncoding: Bool = false
    var exportsHDR: Bool = false

    var resolvedEncoderQuality: Double {
        guard qualityMode == .crfLike else { return 0.85 }
        let normalized = 1.0 - ((min(max(crfLikeValue, 16), 34) - 16) / 18.0)
        return min(max(0.48 + normalized * 0.47, 0.48), 0.95)
    }

    func resolvedBitrate(width: Int, height: Int, frameRate: Double) -> Int {
        if qualityMode == .bitrate {
            return Int(max(0.3, targetBitrateMbps) * 1_000_000)
        }

        let clampedCRF = min(max(crfLikeValue, 16), 34)
        let bppAtCRF23 = 0.30
        let bpp = bppAtCRF23 * pow(2.0, (23.0 - clampedCRF) / 6.0)
        let pixels = Double(max(width * height, 1))
        let fps = max(frameRate, 24)
        let codecMultiplier = codec == .h265 ? 0.72 : 1.0
        let raw = pixels * fps * bpp * codecMultiplier * speedPreset.bitrateMultiplier
        return Int(min(max(raw, 350_000), 50_000_000))
    }

    var keyFrameIntervalDuration: Double {
        switch speedPreset {
        case .compact:
            return 12
        case .medium:
            return 8
        case .quality:
            return 6
        }
    }

    var maxFrameDelayCount: Int {
        switch speedPreset {
        case .compact:
            return 4
        case .medium:
            return 3
        case .quality:
            return 2
        }
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
