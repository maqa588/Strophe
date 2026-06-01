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

    var errorDescription: String? {
        switch self {
        case .missingMedia:
            return String(localized: "当前项目没有可导出的视频。")
        case .missingVideoTrack:
            return String(localized: "当前媒体没有视频轨道。")
        case .unsupportedInput(let ext):
            return String(localized: "当前 V1 硬字幕导出暂不支持 \(ext.uppercased()) 容器。请先导出或转封装为 MP4/MOV。")
        case .cannotCreateReader:
            return String(localized: "无法创建 AVAssetReader。")
        case .cannotCreateWriter:
            return String(localized: "无法创建 AVAssetWriter。")
        case .cannotStartReading(let message):
            return String(localized: "无法开始读取视频：\(message)")
        case .cannotStartWriting(let message):
            return String(localized: "无法开始写入视频：\(message)")
        case .cancelled:
            return String(localized: "硬字幕导出已取消。")
        case .writerFailed(let message):
            return String(localized: "视频写入失败：\(message)")
        case .readerFailed(let message):
            return String(localized: "视频读取失败：\(message)")
        case .audioMuxFailed(let message):
            return String(localized: "音频复用失败：\(message)")
        }
    }
}

enum HardSubtitleVideoCodec: String, CaseIterable, Identifiable, Sendable {
    case h264
    case h265
    case proRes422

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .h265: return "H.265 / HEVC"
        case .proRes422: return "Apple ProRes 422"
        }
    }

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .h265: return .hevc
        case .proRes422: return .proRes422
        }
    }

    var fileType: AVFileType {
        switch self {
        case .h264, .h265: return .mp4
        case .proRes422: return .mov
        }
    }

    var contentType: UTType {
        switch self {
        case .h264, .h265: return .mpeg4Movie
        case .proRes422: return .quickTimeMovie
        }
    }

    var fileExtension: String {
        switch self {
        case .h264, .h265: return "mp4"
        case .proRes422: return "mov"
        }
    }

    func outputSettings(width: Int, height: Int, frameRate: Double, exportSettings: HardSubtitleVideoExportSettings) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]

        if self != .proRes422 {
            let bitrate = exportSettings.resolvedBitrate(width: width, height: height, frameRate: frameRate)
            let quality = exportSettings.resolvedEncoderQuality
            var compressionProperties: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoQualityKey: quality,
                AVVideoExpectedSourceFrameRateKey: Int(max(1, frameRate.rounded())),
                AVVideoMaxKeyFrameIntervalKey: Int(max(30, frameRate.rounded() * 2)),
                AVVideoProfileLevelKey: self == .h265
                    ? (kVTProfileLevel_HEVC_Main_AutoLevel as String)
                    : AVVideoProfileLevelH264HighAutoLevel
            ]
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
        case .bitrate: return "目标码率"
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
        return Int(min(max(raw, 350_000), 80_000_000))
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

enum HardSubtitleVideoExporter {
    @MainActor
    static func export(
        project: SubtitleProject,
        settings: HardSubtitleVideoExportSettings,
        destinationURL: URL,
        progress: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws {
        guard let mediaURL = project.videoURL else {
            throw HardSubtitleVideoExportError.missingMedia
        }

        let inputURL = project.resolveOriginalURL(mediaURL)
        let cues = project.resolvedSubtitleCues()

        try await export(
            inputURL: inputURL,
            cues: cues,
            settings: settings,
            destinationURL: destinationURL,
            progress: progress
        )
    }

    static func export(
        inputURL: URL,
        cues: [ResolvedSubtitleCue],
        settings: HardSubtitleVideoExportSettings,
        destinationURL: URL,
        progress: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws {
        let codec = settings.codec
        let unsupportedExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "rmvb"]
        let ext = inputURL.pathExtension.lowercased()
        if unsupportedExtensions.contains(ext) {
            throw HardSubtitleVideoExportError.unsupportedInput(ext)
        }

        let didAccessInput = inputURL.startAccessingSecurityScopedResource()
        let didAccessOutput = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessInput { inputURL.stopAccessingSecurityScopedResource() }
            if didAccessOutput { destinationURL.stopAccessingSecurityScopedResource() }
        }

        try? FileManager.default.removeItem(at: destinationURL)

        let asset = AVURLAsset(url: inputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw HardSubtitleVideoExportError.missingVideoTrack
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let duration = try await asset.load(.duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let formatDescriptions = (try? await videoTrack.load(.formatDescriptions)) ?? []
        let geometry = renderGeometry(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            formatDescriptions: formatDescriptions,
            usesDisplayAspect: settings.usesDisplayAspect
        )
        let renderSize = geometry.renderSize

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw HardSubtitleVideoExportError.cannotCreateReader
        }

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw HardSubtitleVideoExportError.cannotCreateReader
        }
        reader.add(videoOutput)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destinationURL, fileType: codec.fileType)
        } catch {
            throw HardSubtitleVideoExportError.cannotCreateWriter
        }

        var audioPipes: [AudioPipe] = []
        for audioTrack in audioTracks {
            let sourceFormatHint = ((try? await audioTrack.load(.formatDescriptions)) ?? []).first
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            audioOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(audioOutput) else {
                throw HardSubtitleVideoExportError.cannotCreateReader
            }
            reader.add(audioOutput)

            let audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: sourceFormatHint
            )
            audioInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(audioInput) else {
                throw HardSubtitleVideoExportError.cannotCreateWriter
            }
            writer.add(audioInput)
            audioPipes.append(AudioPipe(output: audioOutput, input: audioInput))
        }

        let width = Int(renderSize.width.rounded(.toNearestOrAwayFromZero))
        let height = Int(renderSize.height.rounded(.toNearestOrAwayFromZero))
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: codec.outputSettings(
                width: width,
                height: height,
                frameRate: Double(nominalFrameRate),
                exportSettings: settings
            )
        )
        writerInput.expectsMediaDataInRealTime = false
        if nominalFrameRate > 0 {
            writerInput.mediaTimeScale = CMTimeScale(max(600, Int32(nominalFrameRate.rounded()) * 100))
        }

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )

        guard writer.canAdd(writerInput) else {
            throw HardSubtitleVideoExportError.cannotCreateWriter
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw HardSubtitleVideoExportError.cannotStartReading(reader.error?.localizedDescription ?? "Unknown error")
        }

        guard writer.startWriting() else {
            throw HardSubtitleVideoExportError.cannotStartWriting(writer.error?.localizedDescription ?? "Unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        let compositor = MetalSubtitleCompositor()
        let sortedCues = cues.sorted { $0.startTime < $1.startTime }
        var cueIndex = 0
        let durationSeconds = max(duration.seconds.isFinite ? duration.seconds : 0, 0.001)

        while reader.status == .reading {
            if Task.isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                throw HardSubtitleVideoExportError.cancelled
            }

            guard writerInput.isReadyForMoreMediaData else {
                try await Task.sleep(nanoseconds: 2_000_000)
                continue
            }

            guard let sample = videoOutput.copyNextSampleBuffer() else {
                break
            }

            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample),
                  let pool = adaptor.pixelBufferPool else {
                writerInput.markAsFinished()
                writer.cancelWriting()
                throw SubtitleCompositorError.outputPoolUnavailable
            }

            var outputBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer) == kCVReturnSuccess,
                  let outputBuffer else {
                writerInput.markAsFinished()
                writer.cancelWriting()
                throw SubtitleCompositorError.pixelBufferCreationFailed
            }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            let seconds = presentationTime.seconds.isFinite ? presentationTime.seconds : 0
            let cue = activeCue(at: seconds, cues: sortedCues, index: &cueIndex)

            try compositor.render(
                sourcePixelBuffer: sourceBuffer,
                outputPixelBuffer: outputBuffer,
                cue: cue,
                renderSize: renderSize,
                preferredTransform: preferredTransform,
                sourceDisplaySize: geometry.sourceDisplaySize
            )

            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }

            guard adaptor.append(outputBuffer, withPresentationTime: presentationTime) else {
                writerInput.markAsFinished()
                writer.cancelWriting()
                throw HardSubtitleVideoExportError.writerFailed(writer.error?.localizedDescription ?? "Unknown error")
            }

            try await drainAudioPipes(
                &audioPipes,
                upTo: presentationTime + CMTime(seconds: 1, preferredTimescale: 600),
                writer: writer
            )

            let videoProgressScale = audioPipes.isEmpty ? 1.0 : 0.96
            let fraction = min(max(seconds / durationSeconds, 0), 1) * videoProgressScale
            await MainActor.run {
                progress(fraction)
            }
        }

        writerInput.markAsFinished()

        try await drainAudioPipes(&audioPipes, upTo: nil, writer: writer)
        audioPipes.forEach { $0.input.markAsFinished() }

        if reader.status == .failed {
            writer.cancelWriting()
            throw HardSubtitleVideoExportError.readerFailed(reader.error?.localizedDescription ?? "Unknown error")
        }

        try await finish(writer: writer)

        await MainActor.run {
            progress(1)
        }
    }

    private struct AudioPipe {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        var pendingSample: CMSampleBuffer?
        var isFinished = false
    }

    private static func drainAudioPipes(
        _ pipes: inout [AudioPipe],
        upTo limit: CMTime?,
        writer: AVAssetWriter
    ) async throws {
        for index in pipes.indices {
            while !pipes[index].isFinished {
                if Task.isCancelled {
                    writer.cancelWriting()
                    throw HardSubtitleVideoExportError.cancelled
                }

                guard pipes[index].input.isReadyForMoreMediaData else {
                    if limit == nil {
                        try await Task.sleep(nanoseconds: 2_000_000)
                        continue
                    }
                    break
                }

                let sample = pipes[index].pendingSample ?? pipes[index].output.copyNextSampleBuffer()
                guard let sample else {
                    pipes[index].isFinished = true
                    break
                }

                if let limit {
                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
                    if presentationTime.isValid, presentationTime > limit {
                        pipes[index].pendingSample = sample
                        break
                    }
                }

                pipes[index].pendingSample = nil
                guard pipes[index].input.append(sample) else {
                    writer.cancelWriting()
                    throw HardSubtitleVideoExportError.audioMuxFailed(writer.error?.localizedDescription ?? "Unknown error")
                }
            }
        }
    }

    private static func activeCue(
        at seconds: Double,
        cues: [ResolvedSubtitleCue],
        index: inout Int
    ) -> ResolvedSubtitleCue? {
        while index < cues.count, cues[index].endTime < seconds {
            index += 1
        }

        guard index < cues.count else { return nil }
        let cue = cues[index]
        return seconds >= cue.startTime && seconds <= cue.endTime ? cue : nil
    }

    private struct RenderGeometry {
        var renderSize: CGSize
        var sourceDisplaySize: CGSize?
    }

    private static func renderGeometry(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        formatDescriptions: [CMFormatDescription],
        usesDisplayAspect: Bool
    ) -> RenderGeometry {
        if usesDisplayAspect,
           let displaySize = displaySize(from: formatDescriptions, fallback: naturalSize) {
            let transformed = transformedSize(displaySize, preferredTransform: preferredTransform)
            return RenderGeometry(
                renderSize: evenSize(transformed),
                sourceDisplaySize: evenSize(transformed)
            )
        }

        return RenderGeometry(
            renderSize: evenSize(transformedSize(naturalSize, preferredTransform: preferredTransform)),
            sourceDisplaySize: nil
        )
    }

    private static func transformedSize(
        _ size: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        let rect = CGRect(origin: .zero, size: size).applying(preferredTransform)
        let width = abs(rect.width).rounded(.toNearestOrAwayFromZero)
        let height = abs(rect.height).rounded(.toNearestOrAwayFromZero)
        if width > 0, height > 0 {
            return CGSize(width: width, height: height)
        }
        return size
    }

    private static func evenSize(_ size: CGSize) -> CGSize {
        let width = max(2, Int(size.width.rounded(.toNearestOrAwayFromZero))) & ~1
        let height = max(2, Int(size.height.rounded(.toNearestOrAwayFromZero))) & ~1
        return CGSize(width: width, height: height)
    }

    private static func displaySize(
        from formatDescriptions: [CMFormatDescription],
        fallback naturalSize: CGSize
    ) -> CGSize? {
        guard let description = formatDescriptions.first else { return nil }

        let aperture = CMVideoFormatDescriptionGetCleanAperture(description, originIsAtTopLeft: false)
        let encoded = CMVideoFormatDescriptionGetDimensions(description)
        let storageWidth = aperture.width > 0 ? aperture.width : CGFloat(encoded.width)
        let storageHeight = aperture.height > 0 ? aperture.height : CGFloat(encoded.height)
        guard storageWidth > 0, storageHeight > 0 else { return nil }

        let pixelAspect = pixelAspectRatio(from: description)
        let displayWidth = storageWidth * pixelAspect
        let displaySize = CGSize(width: displayWidth, height: storageHeight)

        let differsFromNatural = abs(displaySize.width - naturalSize.width) > 0.5
            || abs(displaySize.height - naturalSize.height) > 0.5
        let differsFromSquarePixels = abs(pixelAspect - 1) > 0.001
        return differsFromNatural || differsFromSquarePixels ? displaySize : nil
    }

    private static func pixelAspectRatio(from description: CMFormatDescription) -> CGFloat {
        guard let extensionValue = CMFormatDescriptionGetExtension(
            description,
            extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio
        ) else {
            return 1
        }

        guard let dictionary = extensionValue as? NSDictionary else {
            return 1
        }
        let horizontal = dictionary[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] as? NSNumber
        let vertical = dictionary[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] as? NSNumber
        guard let horizontal, let vertical, vertical.doubleValue > 0 else {
            return 1
        }

        return CGFloat(horizontal.doubleValue / vertical.doubleValue)
    }

    private static func finish(writer: AVAssetWriter) async throws {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if writer.status == .failed {
            throw HardSubtitleVideoExportError.writerFailed(writer.error?.localizedDescription ?? "Unknown error")
        }
    }
}
