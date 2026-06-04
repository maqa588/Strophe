import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import VideoToolbox



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
        let unsupportedExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "rmvb"]
        let ext = inputURL.pathExtension.lowercased()
        if unsupportedExtensions.contains(ext) {
            try await exportViaFFmpeg(
                inputURL: inputURL,
                cues: cues,
                settings: settings,
                destinationURL: destinationURL,
                progress: progress
            )
            return
        }

        try await exportViaAVFoundation(
            inputURL: inputURL,
            cues: cues,
            settings: settings,
            destinationURL: destinationURL,
            progress: progress
        )
    }

    private static func exportViaAVFoundation(
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

        let exportPixelFormat = outputPixelFormat(for: settings)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: pixelBufferAttributes(
                pixelFormat: exportPixelFormat,
                width: nil,
                height: nil
            )
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
        writer.startSession(atSourceTime: .zero)

        let compositor = MetalSubtitleCompositor()
        let sortedCues = cues.sorted { $0.startTime < $1.startTime }
        let cueIndex = 0
        let durationSeconds = max(duration.seconds.isFinite ? duration.seconds : 0, 0.001)

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
            renderSize: renderSize,
            preferredTransform: preferredTransform,
            sourceDisplaySize: geometry.sourceDisplaySize,
            durationSeconds: durationSeconds,
            progress: progress
        )

        if reader.status == .failed {
            writer.cancelWriting()
            throw HardSubtitleVideoExportError.readerFailed(reader.error?.localizedDescription ?? "Unknown error")
        }

        try await finish(writer: writer)

        await MainActor.run {
            progress(1)
        }
    }

    private static func exportViaFFmpeg(
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



    private static func writeAVFoundationStreams(
        reader: AVAssetReader,
        videoOutput: AVAssetReaderTrackOutput,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        audioPipes: [AudioPipe],
        writer: AVAssetWriter,
        compositor: MetalSubtitleCompositor,
        sortedCues: [ResolvedSubtitleCue],
        cueIndex: Int,
        renderSize: CGSize,
        preferredTransform: CGAffineTransform,
        sourceDisplaySize: CGSize?,
        durationSeconds: Double,
        progress: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws {
        let group = MediaWriteGroup(count: 1 + audioPipes.count)
        let videoQueue = DispatchQueue(label: "com.strophe.export.video-writer", qos: .userInitiated)
        let audioQueue = DispatchQueue(label: "com.strophe.export.audio-writer", qos: .userInitiated, attributes: .concurrent)
        let cueCursor = SubtitleCueCursor(index: cueIndex)

        let context = AVFoundationWriteContext(
            reader: reader,
            videoOutput: videoOutput,
            videoInput: videoInput,
            adaptor: adaptor,
            audioPipes: audioPipes,
            writer: writer,
            compositor: compositor,
            sortedCues: sortedCues,
            cueCursor: cueCursor,
            renderSize: renderSize,
            preferredTransform: preferredTransform,
            sourceDisplaySize: sourceDisplaySize,
            durationSeconds: durationSeconds,
            progress: progress,
            group: group
        )

        context.start(videoQueue: videoQueue, audioQueue: audioQueue)

        let cancelContext = MediaWriteCancelContext(reader: reader, writer: writer, group: group)
        try await withTaskCancellationHandler {
            try await group.wait()
        } onCancel: {
            cancelContext.cancel()
        }
    }

    private static func writeFFmpegStreams(
        videoReader: FFmpegVideoExportVideoReader,
        audioReader: FFmpegVideoExportAudioReader?,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        audioInput: AVAssetWriterInput?,
        writer: AVAssetWriter,
        compositor: MetalSubtitleCompositor,
        sortedCues: [ResolvedSubtitleCue],
        cueIndex: Int,
        renderSize: CGSize,
        sourceDisplaySize: CGSize?,
        frameDuration: CMTime,
        durationSeconds: Double,
        progress: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws -> CMTime {
        let hasAudio = audioReader != nil && audioInput != nil
        let group = MediaWriteGroup(count: hasAudio ? 2 : 1)
        let videoQueue = DispatchQueue(label: "com.strophe.export.ffmpeg-video-writer", qos: .userInitiated)
        let audioQueue = DispatchQueue(label: "com.strophe.export.ffmpeg-audio-writer", qos: .userInitiated)
        let cueCursor = SubtitleCueCursor(index: cueIndex)
        let videoState = FFmpegVideoWriteState()
        let audioWriteContext = audioReader.flatMap { audioReader in
            audioInput.map { audioInput in
                FFmpegAudioWriteContext(
                    audioReader: audioReader,
                    audioInput: audioInput,
                    writer: writer,
                    group: group,
                    queue: audioQueue,
                    durationSeconds: durationSeconds,
                    progress: progress
                )
            }
        }

        let context = FFmpegVideoWriteContext(
            videoReader: videoReader,
            videoInput: videoInput,
            adaptor: adaptor,
            writer: writer,
            compositor: compositor,
            sortedCues: sortedCues,
            cueCursor: cueCursor,
            renderSize: renderSize,
            sourceDisplaySize: sourceDisplaySize,
            frameDuration: frameDuration,
            durationSeconds: durationSeconds,
            progress: progress,
            group: group,
            videoState: videoState,
            hasAudio: hasAudio,
            audioWriteContext: audioWriteContext
        )

        context.start(queue: videoQueue)

        let cancelContext = MediaWriteCancelContext(writer: writer, group: group)
        try await withTaskCancellationHandler {
            try await group.wait()
        } onCancel: {
            cancelContext.cancel()
        }
        return videoState.lastVideoTime
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
                    if !pipes[index].hasMarkedFinished {
                        pipes[index].input.markAsFinished()
                        pipes[index].hasMarkedFinished = true
                    }
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

    private static func drainFFmpegAudio(
        _ reader: FFmpegVideoExportAudioReader,
        input: AVAssetWriterInput,
        upTo limit: CMTime?,
        writer: AVAssetWriter,
        progress: (@MainActor @Sendable (Double) -> Void)? = nil,
        durationSeconds: Double? = nil
    ) async throws {
        var lastProgressUpdate = CFAbsoluteTimeGetCurrent()
        while !reader.isFinished {
            if Task.isCancelled {
                writer.cancelWriting()
                throw HardSubtitleVideoExportError.cancelled
            }

            guard input.isReadyForMoreMediaData else {
                if limit == nil {
                    try await Task.sleep(nanoseconds: 2_000_000)
                    continue
                }
                break
            }

            let sample = try reader.peekSampleBuffer()
            guard let sample else { break }

            if let limit {
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
                if presentationTime.isValid, presentationTime > limit {
                    break
                }
            }

            _ = try reader.consumePeekedSampleBuffer()
            guard input.append(sample) else {
                writer.cancelWriting()
                throw HardSubtitleVideoExportError.audioMuxFailed(writer.error?.localizedDescription ?? "Unknown error")
            }

            if let progress, let durationSeconds, durationSeconds > 0 {
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastProgressUpdate > 0.1 {
                    lastProgressUpdate = now
                    let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if seconds.isFinite {
                        let fraction = 0.96 + min(max(seconds / durationSeconds, 0), 1) * 0.03
                        await MainActor.run {
                            progress(fraction)
                        }
                    }
                }
            }
        }
    }

    private static func waitForFFmpegVideoInputReady(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter,
        audioReader: FFmpegVideoExportAudioReader?,
        audioInput: AVAssetWriterInput?,
        isAudioFinished: inout Bool,
        audioLimit: CMTime,
        seconds: Double,
        durationSeconds: Double,
        progress: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws -> Bool {
        let started = CFAbsoluteTimeGetCurrent()
        let tailTolerance = max(1.5, min(5.0, durationSeconds * 0.02))
        let isTailFrame = seconds >= durationSeconds - tailTolerance
        let timeout = isTailFrame ? 5.0 : 20.0
        var lastLog = started

        while !input.isReadyForMoreMediaData {
            if Task.isCancelled {
                writer.cancelWriting()
                throw HardSubtitleVideoExportError.cancelled
            }
            if writer.status == .failed {
                throw HardSubtitleVideoExportError.writerFailed(writer.error?.localizedDescription ?? "Unknown error")
            }

            if let audioReader, let audioInput, !isAudioFinished {
                try await drainFFmpegAudio(
                    audioReader,
                    input: audioInput,
                    upTo: audioLimit,
                    writer: writer,
                    progress: progress,
                    durationSeconds: durationSeconds
                )
                if audioReader.isFinished {
                    audioInput.markAsFinished()
                    isAudioFinished = true
                }
            }

            let now = CFAbsoluteTimeGetCurrent()
            let waited = now - started
            if now - lastLog > 5.0 {
                lastLog = now
                print("🎞️ FFmpeg hard-sub export: waiting for video writer readiness at \(String(format: "%.2f", seconds))s (\(String(format: "%.1f", waited))s)")
            }
            if waited > timeout {
                if isTailFrame {
                    print("🎞️ FFmpeg hard-sub export: video writer stayed not-ready at tail for \(String(format: "%.1f", waited))s; ending video track at source duration \(String(format: "%.2f", durationSeconds))s")
                    return false
                }
                writer.cancelWriting()
                throw HardSubtitleVideoExportError.writerFailed("VideoToolbox writer stayed not-ready for \(String(format: "%.1f", waited))s at \(String(format: "%.2f", seconds))s.")
            }

            try await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
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

    private static func outputPixelFormat(for settings: HardSubtitleVideoExportSettings) -> OSType {
        guard settings.usesExperimentalNV12PixelBuffers,
              !settings.codec.isProRes else {
            return kCVPixelFormatType_32BGRA
        }
        return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    private static func configureVideoWriterInput(
        _ input: AVAssetWriterInput,
        settings: HardSubtitleVideoExportSettings
    ) {
        guard !settings.codec.isProRes else { return }
        input.performsMultiPassEncodingIfSupported = settings.usesMultiPassEncoding
    }

    private static func pixelBufferAttributes(
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

    private static func renderGeometry(
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

    private static func temporaryExportURL(fileExtension: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StropheExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
    }

    private static func replaceExport(at destinationURL: URL, with temporaryURL: URL) throws {
        try? FileManager.default.removeItem(at: destinationURL)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }
}
