import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import VideoToolbox

extension HardSubtitleVideoExporter {
    static func exportViaFFmpeg(
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

        // NSSavePanel/fileExporter grants access to the selected file URL, not
        // necessarily to arbitrary sibling files in its parent directory.
        // Write directly to that authorized URL. This also avoids a second,
        // potentially multi-gigabyte copy after ProRes encoding.
        let workingURL = destinationURL
        var didFinishOutput = false
        defer {
            if !didFinishOutput {
                try? FileManager.default.removeItem(at: workingURL)
            }
        }
        try? FileManager.default.removeItem(at: workingURL)

        let videoReader = try FFmpegVideoExportVideoReader(url: inputURL)
        defer { videoReader.close() }
        let outputColorProfile = try resolvedOutputColorProfile(
            settings: settings,
            sourceProfile: videoReader.sourceColorProfile
        )

        // The video reader already paid for avformat_find_stream_info. Reuse
        // that result instead of opening and probing a second FFmpeg context.
        let detectedAudioTrackCount = videoReader.audioStreamCount
        let requestedAudioTrackOrdinals: [Int]
        if let selected = settings.includedAudioTrackOrdinals {
            requestedAudioTrackOrdinals =
                selected
                .filter { $0 >= 0 && $0 < detectedAudioTrackCount }
                .sorted()
        } else {
            requestedAudioTrackOrdinals = Array(0..<detectedAudioTrackCount)
        }
        var audioReaders: [FFmpegVideoExportAudioReader] = []
        for ordinal in requestedAudioTrackOrdinals {
            if let reader = try? FFmpegVideoExportAudioReader(
                url: inputURL,
                audioTrackOrdinal: ordinal
            ) {
                audioReaders.append(reader)
            }
        }
        defer { audioReaders.forEach { $0.close() } }

        let geometry = renderGeometry(
            naturalSize: videoReader.storageSize,
            sampleAspectRatio: videoReader.sampleAspectRatio,
            usesDisplayAspect: settings.usesDisplayAspect
        )
        let renderSize = geometry.renderSize
        let width = Int(renderSize.width.rounded(.toNearestOrAwayFromZero))
        let height = Int(renderSize.height.rounded(.toNearestOrAwayFromZero))
        let frameRate = videoReader.frameRate > 0 ? videoReader.frameRate : 30
        let exportRange = try settings.resolvedTimeRange(
            maxDuration: videoReader.duration
        )
        let timelineStartSeconds = exportRange?.lowerBound ?? 0
        let durationSeconds = max(
            exportRange.map { $0.upperBound - $0.lowerBound }
                ?? videoReader.duration,
            0.001
        )
        for audioReader in audioReaders {
            audioReader.minimumSourceTime = timelineStartSeconds
            audioReader.maximumSourceTime = exportRange?.upperBound
            if timelineStartSeconds > 0 {
                _ = audioReader.seek(to: timelineStartSeconds)
            }
        }
        if timelineStartSeconds > 0 {
            _ = videoReader.seek(to: timelineStartSeconds)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: workingURL, fileType: codec.fileType)
        } catch {
            throw HardSubtitleVideoExportError.cannotCreateWriter
        }
        print("🎞️ FFmpeg hard-sub export: writing authorized output at \(workingURL.path)")

        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: codec.outputSettings(
                width: width,
                height: height,
                frameRate: frameRate,
                exportSettings: settings,
                colorProfile: outputColorProfile
            )
        )
        writerInput.expectsMediaDataInRealTime = false
        configureVideoWriterInput(writerInput, settings: settings)
        writerInput.mediaTimeScale = CMTimeScale(max(600, Int32(frameRate.rounded()) * 100))
        let exportPixelFormat = outputPixelFormat(
            for: settings,
            colorProfile: outputColorProfile
        )

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

        var audioPipes: [FFmpegAudioPipe] = []
        for audioReader in audioReaders {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioReader.writerOutputSettings
            )
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioPipes.append(
                    FFmpegAudioPipe(reader: audioReader, input: input)
                )
            }
        }

        guard writer.startWriting() else {
            throw HardSubtitleVideoExportError.cannotStartWriting(writer.error?.localizedDescription ?? "Unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        let compositor = MetalSubtitleCompositor(
            outputColorProfile: outputColorProfile,
            rendersTransparentBackground: settings.rendersTransparentBackground,
            overlays: VideoBurnInOverlaySettings(
                exportSettings: settings,
                frameRate: frameRate,
                timelineStartSeconds: timelineStartSeconds
            )
        )
        let sortedCues = cues.sorted { $0.startTime < $1.startTime }
        let cueIndex = 0
        let frameDuration = CMTime(
            seconds: 1.0 / max(frameRate, 1.0),
            preferredTimescale: writerInput.mediaTimeScale
        )

        let lastVideoPresentationTime = try await writeFFmpegStreams(
            videoReader: videoReader,
            audioPipes: audioPipes,
            videoInput: writerInput,
            adaptor: adaptor,
            writer: writer,
            compositor: compositor,
            sortedCues: sortedCues,
            cueIndex: cueIndex,
            collisionMode: collisionMode,
            renderSize: renderSize,
            sourceDisplaySize: geometry.sourceDisplaySize,
            frameDuration: frameDuration,
            sourceRange: exportRange,
            durationSeconds: durationSeconds,
            allowsDirectFramePassThrough:
                !settings.rendersTransparentBackground
                && videoReader.sourceColorProfile == outputColorProfile
                && geometry.sourceDisplaySize == nil
                && evenSize(videoReader.storageSize) == renderSize,
            directPassThroughPixelFormat: exportPixelFormat,
            maxInFlightFrames: renderPipelineDepth(
                settings: settings,
                renderSize: renderSize,
                pixelFormat: exportPixelFormat
            ),
            progress: progress
        )
        print("🎞️ FFmpeg hard-sub export: video input finished at \(lastVideoPresentationTime.seconds)")

        guard lastVideoPresentationTime.isValid else {
            writer.cancelWriting()
            throw HardSubtitleVideoExportError.writerFailed(
                "No decodable video frames fell inside the requested export range."
            )
        }
        let appendedVideoEnd = CMTimeAdd(lastVideoPresentationTime, frameDuration)
        let sourceEnd = CMTime(seconds: durationSeconds, preferredTimescale: writerInput.mediaTimeScale)
        writer.endSession(atSourceTime: CMTimeMaximum(appendedVideoEnd, sourceEnd))

        print("🎞️ FFmpeg hard-sub export: finishing writer")
        try await finish(writer: writer)
        didFinishOutput = true
        print("🎞️ FFmpeg hard-sub export: writer finished at \(destinationURL.path)")

        await MainActor.run {
            progress(1)
        }
    }
}
