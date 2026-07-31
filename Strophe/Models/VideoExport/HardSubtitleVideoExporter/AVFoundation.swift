import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import VideoToolbox

extension HardSubtitleVideoExporter {
    static func exportViaAVFoundation(
        inputURL: URL,
        cues: [ResolvedSubtitleCue],
        collisionMode: SubtitleCollisionMode,
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

        var didFinishOutput = false
        defer {
            if !didFinishOutput {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }
        try? FileManager.default.removeItem(at: destinationURL)

        let asset = AVURLAsset(url: inputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw HardSubtitleVideoExportError.missingVideoTrack
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let duration = try await asset.load(.duration)
        let sourceDurationSeconds = max(duration.seconds.isFinite ? duration.seconds : 0, 0)
        let exportRange = try settings.resolvedTimeRange(maxDuration: sourceDurationSeconds)
        let timelineStartSeconds = exportRange?.lowerBound ?? 0
        let durationSeconds = max(
            exportRange.map { $0.upperBound - $0.lowerBound } ?? sourceDurationSeconds,
            0.001
        )
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let formatDescriptions = (try? await videoTrack.load(.formatDescriptions)) ?? []
        let sourceColorProfile = VideoColorProfile.detect(in: formatDescriptions)
        let outputColorProfile = try resolvedOutputColorProfile(
            settings: settings,
            sourceProfile: sourceColorProfile
        )
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
        if let exportRange {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: exportRange.lowerBound, preferredTimescale: 600),
                duration: CMTime(
                    seconds: exportRange.upperBound - exportRange.lowerBound,
                    preferredTimescale: 600
                )
            )
        }

        let exportPixelFormat = outputPixelFormat(
            for: settings,
            colorProfile: outputColorProfile
        )
        let readerVideoSettings = videoReaderOutputSettings(
            pixelFormat: exportPixelFormat,
            colorProfile: outputColorProfile
        )
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: readerVideoSettings
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
        for (ordinal, audioTrack) in audioTracks.enumerated()
        where settings.includesAudioTrack(ordinal: ordinal) {
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
                exportSettings: settings,
                colorProfile: outputColorProfile
            )
        )
        writerInput.expectsMediaDataInRealTime = false
        configureVideoWriterInput(writerInput, settings: settings)
        if nominalFrameRate > 0 {
            writerInput.mediaTimeScale = CMTimeScale(max(600, Int32(nominalFrameRate.rounded()) * 100))
        }

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

        guard reader.startReading() else {
            throw HardSubtitleVideoExportError.cannotStartReading(reader.error?.localizedDescription ?? "Unknown error")
        }

        guard writer.startWriting() else {
            throw HardSubtitleVideoExportError.cannotStartWriting(writer.error?.localizedDescription ?? "Unknown error")
        }
        writer.startSession(
            atSourceTime: CMTime(seconds: timelineStartSeconds, preferredTimescale: 600)
        )

        let compositor = MetalSubtitleCompositor(
            outputColorProfile: outputColorProfile,
            rendersTransparentBackground: settings.rendersTransparentBackground,
            overlays: VideoBurnInOverlaySettings(
                exportSettings: settings,
                frameRate: Double(nominalFrameRate),
                timelineStartSeconds: timelineStartSeconds
            )
        )
        let sortedCues = cues.sorted { $0.startTime < $1.startTime }
        let cueIndex = 0

        try await writeAVFoundationStreams(
            reader: reader,
            videoOutput: videoOutput,
            videoInput: writerInput,
            adaptor: adaptor,
            audioPipes: audioPipes,
            writer: writer,
            compositor: compositor,
            sortedCues: sortedCues,
            cueIndex: cueIndex,
            collisionMode: collisionMode,
            renderSize: renderSize,
            preferredTransform: preferredTransform,
            sourceDisplaySize: geometry.sourceDisplaySize,
            timelineStartSeconds: timelineStartSeconds,
            durationSeconds: durationSeconds,
            allowsDirectFramePassThrough:
                !settings.rendersTransparentBackground
                && sourceColorProfile == outputColorProfile
                && preferredTransform.isIdentity
                && geometry.sourceDisplaySize == nil
                && evenSize(naturalSize) == renderSize,
            directPassThroughPixelFormat: exportPixelFormat,
            maxInFlightFrames: renderPipelineDepth(
                settings: settings,
                renderSize: renderSize,
                pixelFormat: exportPixelFormat
            ),
            progress: progress
        )

        if reader.status == .failed {
            writer.cancelWriting()
            throw HardSubtitleVideoExportError.readerFailed(reader.error?.localizedDescription ?? "Unknown error")
        }

        try await finish(writer: writer)
        didFinishOutput = true

        await MainActor.run {
            progress(1)
        }
    }
}
