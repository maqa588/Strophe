import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import VideoToolbox

extension HardSubtitleVideoExporter {
    static func exportViaFFmpeg(
        inputURL: URL,
        cues: [ResolvedSubtitleCue],
        settings: HardSubtitleVideoExportSettings,
        destinationURL: URL,
        progress: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws {
        let codec = settings.codec
        let didAccessInput = inputURL.startAccessingSecurityScopedResource()
        let didAccessOutput = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessInput { inputURL.stopAccessingSecurityScopedResource() }
            if didAccessOutput { destinationURL.stopAccessingSecurityScopedResource() }
        }

        let workingURL = temporaryExportURL(fileExtension: codec.fileExtension)
        defer {
            try? FileManager.default.removeItem(at: workingURL)
        }
        try? FileManager.default.removeItem(at: workingURL)

        let videoReader = try FFmpegVideoExportVideoReader(url: inputURL)
        defer { videoReader.close() }

        let audioReader = try? FFmpegVideoExportAudioReader(url: inputURL)
        defer { audioReader?.close() }

        let geometry = renderGeometry(
            naturalSize: videoReader.storageSize,
            sampleAspectRatio: videoReader.sampleAspectRatio,
            usesDisplayAspect: settings.usesDisplayAspect
        )
        let renderSize = geometry.renderSize
        let width = Int(renderSize.width.rounded(.toNearestOrAwayFromZero))
        let height = Int(renderSize.height.rounded(.toNearestOrAwayFromZero))
        let frameRate = videoReader.frameRate > 0 ? videoReader.frameRate : 30
        let durationSeconds = max(videoReader.duration, 0.001)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: workingURL, fileType: codec.fileType)
        } catch {
            throw HardSubtitleVideoExportError.cannotCreateWriter
        }
        print("🎞️ FFmpeg hard-sub export: writing temporary file at \(workingURL.path)")

        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: codec.outputSettings(
                width: width,
                height: height,
                frameRate: frameRate,
                exportSettings: settings
            )
        )
        writerInput.expectsMediaDataInRealTime = false
        configureVideoWriterInput(writerInput, settings: settings)
        writerInput.mediaTimeScale = CMTimeScale(max(600, Int32(frameRate.rounded()) * 100))
        let exportPixelFormat = outputPixelFormat(for: settings)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttributes(
                pixelFormat: exportPixelFormat,
                width: width,
                height: height
            )
        )

        guard writer.canAdd(writerInput) else {
            throw HardSubtitleVideoExportError.cannotCreateWriter
        }
        writer.add(writerInput)

        let audioInput: AVAssetWriterInput?
        if let audioReader {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioReader.writerOutputSettings
            )
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else {
            throw HardSubtitleVideoExportError.cannotStartWriting(writer.error?.localizedDescription ?? "Unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        let compositor = MetalSubtitleCompositor()
        let sortedCues = cues.sorted { $0.startTime < $1.startTime }
        let cueIndex = 0
        let frameDuration = CMTime(
            seconds: 1.0 / max(frameRate, 1.0),
            preferredTimescale: writerInput.mediaTimeScale
        )

        let lastVideoPresentationTime = try await writeFFmpegStreams(
            videoReader: videoReader,
            audioReader: audioReader,
            videoInput: writerInput,
            adaptor: adaptor,
            audioInput: audioInput,
            writer: writer,
            compositor: compositor,
            sortedCues: sortedCues,
            cueIndex: cueIndex,
            renderSize: renderSize,
            sourceDisplaySize: geometry.sourceDisplaySize,
            frameDuration: frameDuration,
            durationSeconds: durationSeconds,
            progress: progress
        )
        print("🎞️ FFmpeg hard-sub export: video input finished at \(lastVideoPresentationTime.seconds)")

        if lastVideoPresentationTime.isValid {
            let appendedVideoEnd = CMTimeAdd(lastVideoPresentationTime, frameDuration)
            let sourceEnd = CMTime(seconds: durationSeconds, preferredTimescale: writerInput.mediaTimeScale)
            writer.endSession(atSourceTime: CMTimeMaximum(appendedVideoEnd, sourceEnd))
        }

        print("🎞️ FFmpeg hard-sub export: finishing writer")
        try await finish(writer: writer)
        print("🎞️ FFmpeg hard-sub export: writer finished, moving to \(destinationURL.path)")

        await MainActor.run {
            progress(0.995)
        }
        try replaceExport(at: destinationURL, with: workingURL)

        await MainActor.run {
            progress(1)
        }
    }
}