import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import VideoToolbox


nonisolated enum HardSubtitleVideoExporter {
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
        let collisionMode = project.subtitleCollisionMode

        try await export(
            inputURL: inputURL,
            cues: cues,
            collisionMode: collisionMode,
            settings: settings,
            destinationURL: destinationURL,
            progress: progress
        )
    }

    static func export(
        inputURL: URL,
        cues: [ResolvedSubtitleCue],
        collisionMode: SubtitleCollisionMode = .normal,
        settings: HardSubtitleVideoExportSettings,
        destinationURL: URL,
        progress: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try await exportOnWorker(
                inputURL: inputURL,
                cues: cues,
                collisionMode: collisionMode,
                settings: settings,
                destinationURL: destinationURL,
                progress: progress
            )
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func exportOnWorker(
        inputURL: URL,
        cues: [ResolvedSubtitleCue],
        collisionMode: SubtitleCollisionMode,
        settings: HardSubtitleVideoExportSettings,
        destinationURL: URL,
        progress: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws {
        do {
            try await exportOnce(
                inputURL: inputURL,
                cues: cues,
                collisionMode: collisionMode,
                settings: settings,
                destinationURL: destinationURL,
                progress: progress
            )
        } catch {
            guard shouldRetryWithBGRA(after: error, settings: settings) else {
                throw error
            }

            try Task.checkCancellation()
            var fallbackSettings = settings
            fallbackSettings.usesBGRACompatibilityPixelBuffers = true
            print("🎞️ NV12 hard-subtitle export failed; retrying from the beginning with BGRA: \(error.localizedDescription)")
            await MainActor.run {
                progress(0)
            }
            try await exportOnce(
                inputURL: inputURL,
                cues: cues,
                collisionMode: collisionMode,
                settings: fallbackSettings,
                destinationURL: destinationURL,
                progress: progress
            )
        }
    }

    private static func exportOnce(
        inputURL: URL,
        cues: [ResolvedSubtitleCue],
        collisionMode: SubtitleCollisionMode,
        settings: HardSubtitleVideoExportSettings,
        destinationURL: URL,
        progress: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws {
        let unsupportedExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "rmvb"]
        let ext = inputURL.pathExtension.lowercased()
        if unsupportedExtensions.contains(ext) {
            try await exportViaFFmpeg(
                inputURL: inputURL,
                cues: cues,
                collisionMode: collisionMode,
                settings: settings,
                destinationURL: destinationURL,
                progress: progress
            )
            return
        }

        try await exportViaAVFoundation(
            inputURL: inputURL,
            cues: cues,
            collisionMode: collisionMode,
            settings: settings,
            destinationURL: destinationURL,
            progress: progress
        )
    }

    private static func shouldRetryWithBGRA(
        after error: Error,
        settings: HardSubtitleVideoExportSettings
    ) -> Bool {
        guard !settings.codec.isProRes,
              !settings.exportsHDR,
              !settings.usesBGRACompatibilityPixelBuffers,
              !Task.isCancelled,
              !(error is CancellationError) else {
            return false
        }

        if error is SubtitleCompositorError {
            return true
        }

        guard let exportError = error as? HardSubtitleVideoExportError else {
            return false
        }
        switch exportError {
        case .cannotCreateReader,
             .cannotCreateWriter,
             .cannotStartReading(_),
             .cannotStartWriting(_),
             .writerFailed(_),
             .readerFailed(_):
            return true
        case .missingMedia,
             .missingVideoTrack,
             .unsupportedInput(_),
             .cancelled,
             .audioMuxFailed(_),
             .ffmpegDecodeFailed(_),
             .hdrRequiresCompatibleCodec,
             .hdrSourceRequired,
             .invalidExportRange:
            return false
        }
    }

    // exportViaAVFoundation is in HardSubtitleVideoExporter/AVFoundation.swift
    // exportViaFFmpeg is in HardSubtitleVideoExporter/FFmpeg.swift

    static func resolvedOutputColorProfile(
        settings: HardSubtitleVideoExportSettings,
        sourceProfile: VideoColorProfile
    ) throws -> VideoColorProfile {
        guard settings.exportsHDR else { return .sdr709 }
        guard settings.codec.supportsHDR else {
            throw HardSubtitleVideoExportError.hdrRequiresCompatibleCodec
        }
        guard sourceProfile.isHDR else {
            throw HardSubtitleVideoExportError.hdrSourceRequired
        }
        return sourceProfile
    }

    static func outputPixelFormat(
        for settings: HardSubtitleVideoExportSettings,
        colorProfile: VideoColorProfile
    ) -> OSType {
        if colorProfile.isHDR {
            return colorProfile.pixelFormat
        }
        guard !settings.usesBGRACompatibilityPixelBuffers,
              !settings.codec.isProRes else {
            return kCVPixelFormatType_32BGRA
        }
        return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    static func configureVideoWriterInput(
        _ input: AVAssetWriterInput,
        settings: HardSubtitleVideoExportSettings
    ) {
        guard !settings.codec.isProRes else { return }
        input.performsMultiPassEncodingIfSupported = settings.usesMultiPassEncoding
    }

    static func pixelBufferAttributes(
        pixelFormat: OSType,
        width: Int?,
        height: Int?
    ) -> [String: Any] {
        var attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        if let width {
            attributes[kCVPixelBufferWidthKey as String] = width
        }
        if let height {
            attributes[kCVPixelBufferHeightKey as String] = height
        }

        if pixelFormat == kCVPixelFormatType_32BGRA {
            attributes[kCVPixelBufferCGImageCompatibilityKey as String] = true
            attributes[kCVPixelBufferCGBitmapContextCompatibilityKey as String] = true
        }

        return attributes
    }

    struct RenderGeometry {
        var renderSize: CGSize
        var sourceDisplaySize: CGSize?
    }

    static func renderGeometry(
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

    static func renderGeometry(
        naturalSize: CGSize,
        sampleAspectRatio: CGSize,
        usesDisplayAspect: Bool
    ) -> RenderGeometry {
        let storageSize = evenSize(naturalSize)
        guard usesDisplayAspect,
              sampleAspectRatio.width > 0,
              sampleAspectRatio.height > 0,
              abs(sampleAspectRatio.width - sampleAspectRatio.height) > 0.0001 else {
            return RenderGeometry(renderSize: storageSize, sourceDisplaySize: nil)
        }

        let displayWidth = naturalSize.width * sampleAspectRatio.width / sampleAspectRatio.height
        let displaySize = evenSize(CGSize(width: displayWidth, height: naturalSize.height))
        return RenderGeometry(renderSize: displaySize, sourceDisplaySize: displaySize)
    }

    static func transformedSize(
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

    static func evenSize(_ size: CGSize) -> CGSize {
        let width = max(2, Int(size.width.rounded(.toNearestOrAwayFromZero))) & ~1
        let height = max(2, Int(size.height.rounded(.toNearestOrAwayFromZero))) & ~1
        return CGSize(width: width, height: height)
    }

    static func displaySize(
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

    static func pixelAspectRatio(from description: CMFormatDescription) -> CGFloat {
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

    static func finish(writer: AVAssetWriter) async throws {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            throw HardSubtitleVideoExportError.writerFailed(writer.error?.localizedDescription ?? "Unknown error")
        }
        guard FileManager.default.fileExists(atPath: writer.outputURL.path) else {
            let parent = writer.outputURL.deletingLastPathComponent()
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil
            ))?.map(\.lastPathComponent) ?? []
            print(
                "🎞️ Writer completed without a visible output file. "
                    + "URL=\(writer.outputURL.path), parentExists="
                    + "\(FileManager.default.fileExists(atPath: parent.path)), "
                    + "entries=\(entries)"
            )
            throw HardSubtitleVideoExportError.writerFailed(
                "The media writer completed without creating an output file."
            )
        }
    }

    static func temporaryExportURL(fileExtension: String) -> URL {
        let directory = TempCleanupHelper.exportSessionDirectoryURL
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
    }

    static func replaceExport(at destinationURL: URL, with temporaryURL: URL) throws {
        try? FileManager.default.removeItem(at: destinationURL)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }
}
