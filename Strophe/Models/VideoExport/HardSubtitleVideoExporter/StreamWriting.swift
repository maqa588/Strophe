//
//  HardSubtitleVideoExporter+StreamWriting.swift
//  Strophe
//
//  Created by Antigravity on 2026/07/12.
//

import AVFoundation
import Foundation

extension HardSubtitleVideoExporter {

    static func writeAVFoundationStreams(
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

    static func writeFFmpegStreams(
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

    static func drainAudioPipes(
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

    static func drainFFmpegAudio(
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

    static func waitForFFmpegVideoInputReady(
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
}
