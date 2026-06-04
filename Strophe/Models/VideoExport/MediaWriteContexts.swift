//
//  MediaWriteContexts.swift
//  Strophe
//
//  Created by Antigravity on 2026/06/04.
//

import AVFoundation
import Foundation
import SwiftUI
import VideoToolbox

nonisolated struct AudioPipe: @unchecked Sendable {
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
    var pendingSample: CMSampleBuffer?
    var isFinished = false
    var hasMarkedFinished = false
}

nonisolated final class MediaWriteGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingCount: Int
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    init(count: Int) {
        pendingCount = count
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Void, Error>? = lock.withLock {
                if let failure {
                    return .failure(failure)
                }
                if pendingCount == 0 {
                    return .success(())
                }
                self.continuation = continuation
                return nil
            }

            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func finish() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard pendingCount > 0 else { return nil }
            pendingCount -= 1
            guard pendingCount == 0, failure == nil else { return nil }
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func fail(_ error: Error, writer: AVAssetWriter? = nil) {
        writer?.cancelWriting()
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard failure == nil else { return nil }
            failure = error
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(throwing: error)
    }

    var hasFailed: Bool {
        lock.withLock { failure != nil }
    }
}

private extension NSLock {
    nonisolated func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

nonisolated final class SubtitleCueCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var index: Int

    init(index: Int = 0) {
        self.index = index
    }

    func activeCue(at seconds: Double, cues: [ResolvedSubtitleCue]) -> ResolvedSubtitleCue? {
        lock.withLock {
            while index < cues.count, cues[index].endTime < seconds {
                index += 1
            }

            guard index < cues.count else { return nil }
            let cue = cues[index]
            return seconds >= cue.startTime && seconds <= cue.endTime ? cue : nil
        }
    }
}

nonisolated final class FFmpegVideoWriteState: @unchecked Sendable {
    private let lock = NSLock()
    private var firstVideoPTS: Double?
    private var lastVideoPresentationTime = CMTime.invalid

    func basePTS(for framePTS: Double) -> Double {
        lock.withLock {
            if let firstVideoPTS {
                return firstVideoPTS
            }
            firstVideoPTS = framePTS
            return framePTS
        }
    }

    func adjustedSeconds(for framePTS: Double, basePTS: Double, frameDuration: CMTime) -> Double {
        lock.withLock {
            var seconds = max(0, framePTS - basePTS)
            if lastVideoPresentationTime.isValid {
                let minimumNextSeconds = CMTimeAdd(lastVideoPresentationTime, frameDuration).seconds
                if minimumNextSeconds.isFinite, seconds <= lastVideoPresentationTime.seconds {
                    seconds = minimumNextSeconds
                }
            }
            return seconds
        }
    }

    func setLastVideoPresentationTime(_ time: CMTime) {
        lock.withLock {
            lastVideoPresentationTime = time
        }
    }

    var lastVideoTime: CMTime {
        lock.withLock { lastVideoPresentationTime }
    }
}

nonisolated final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didRun = false

    func run(_ body: () -> Void) {
        let shouldRun = lock.withLock { () -> Bool in
            guard !didRun else { return false }
            didRun = true
            return true
        }
        if shouldRun {
            body()
        }
    }
}

nonisolated final class FFmpegAudioWriteContext: @unchecked Sendable {
    private let audioReader: FFmpegVideoExportAudioReader
    private let audioInput: AVAssetWriterInput
    private let writer: AVAssetWriter
    private let group: MediaWriteGroup
    private let queue: DispatchQueue
    private let durationSeconds: Double
    private let progress: @MainActor @Sendable (Double) -> Void
    private let startGate = OnceGate()

    init(
        audioReader: FFmpegVideoExportAudioReader,
        audioInput: AVAssetWriterInput,
        writer: AVAssetWriter,
        group: MediaWriteGroup,
        queue: DispatchQueue,
        durationSeconds: Double,
        progress: @MainActor @Sendable @escaping (Double) -> Void
    ) {
        self.audioReader = audioReader
        self.audioInput = audioInput
        self.writer = writer
        self.group = group
        self.queue = queue
        self.durationSeconds = durationSeconds
        self.progress = progress
    }

    func start(offset: Double) {
        startGate.run {
            audioReader.timeOffset = offset
            audioInput.requestMediaDataWhenReady(on: queue) { [self] in
                while self.audioInput.isReadyForMoreMediaData, !self.group.hasFailed {
                    do {
                        let sample = try self.audioReader.peekSampleBuffer()
                        guard let sample else {
                            self.audioInput.markAsFinished()
                            self.group.finish()
                            print("🎞️ FFmpeg hard-sub export: audio input finished")
                            return
                        }

                        _ = try self.audioReader.consumePeekedSampleBuffer()
                        guard self.audioInput.append(sample) else {
                            self.audioInput.markAsFinished()
                            self.group.fail(HardSubtitleVideoExportError.audioMuxFailed(self.writer.error?.localizedDescription ?? "Unknown error"), writer: self.writer)
                            return
                        }

                        let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if seconds.isFinite {
                            let fraction = 0.96 + min(max(seconds / self.durationSeconds, 0), 1) * 0.03
                            Task { @MainActor in
                                self.progress(fraction)
                            }
                        }
                    } catch {
                        self.audioInput.markAsFinished()
                        self.group.fail(error, writer: self.writer)
                        return
                    }
                }
            }
        }
    }
}

nonisolated final class AVFoundationWriteContext: @unchecked Sendable {
    private let reader: AVAssetReader
    private let videoOutput: AVAssetReaderTrackOutput
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioPipes: [AudioPipe]
    private let writer: AVAssetWriter
    private let compositor: MetalSubtitleCompositor
    private let sortedCues: [ResolvedSubtitleCue]
    private let cueCursor: SubtitleCueCursor
    private let renderSize: CGSize
    private let preferredTransform: CGAffineTransform
    private let sourceDisplaySize: CGSize?
    private let durationSeconds: Double
    private let progress: @MainActor @Sendable (Double) -> Void
    private let group: MediaWriteGroup

    init(
        reader: AVAssetReader,
        videoOutput: AVAssetReaderTrackOutput,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        audioPipes: [AudioPipe],
        writer: AVAssetWriter,
        compositor: MetalSubtitleCompositor,
        sortedCues: [ResolvedSubtitleCue],
        cueCursor: SubtitleCueCursor,
        renderSize: CGSize,
        preferredTransform: CGAffineTransform,
        sourceDisplaySize: CGSize?,
        durationSeconds: Double,
        progress: @MainActor @Sendable @escaping (Double) -> Void,
        group: MediaWriteGroup
    ) {
        self.reader = reader
        self.videoOutput = videoOutput
        self.videoInput = videoInput
        self.adaptor = adaptor
        self.audioPipes = audioPipes
        self.writer = writer
        self.compositor = compositor
        self.sortedCues = sortedCues
        self.cueCursor = cueCursor
        self.renderSize = renderSize
        self.preferredTransform = preferredTransform
        self.sourceDisplaySize = sourceDisplaySize
        self.durationSeconds = durationSeconds
        self.progress = progress
        self.group = group
    }

    func start(videoQueue: DispatchQueue, audioQueue: DispatchQueue) {
        for pipe in audioPipes {
            pipe.input.requestMediaDataWhenReady(on: audioQueue) { [self] in
                while pipe.input.isReadyForMoreMediaData, !group.hasFailed {
                    if reader.status == .failed {
                        pipe.input.markAsFinished()
                        group.fail(HardSubtitleVideoExportError.readerFailed(reader.error?.localizedDescription ?? "Unknown error"), writer: writer)
                        return
                    }

                    guard let sample = pipe.output.copyNextSampleBuffer() else {
                        pipe.input.markAsFinished()
                        group.finish()
                        return
                    }

                    guard pipe.input.append(sample) else {
                        pipe.input.markAsFinished()
                        group.fail(HardSubtitleVideoExportError.audioMuxFailed(writer.error?.localizedDescription ?? "Unknown error"), writer: writer)
                        return
                    }
                }
            }
        }

        videoInput.requestMediaDataWhenReady(on: videoQueue) { [self] in
            while videoInput.isReadyForMoreMediaData, !group.hasFailed {
                if reader.status == .failed {
                    videoInput.markAsFinished()
                    group.fail(HardSubtitleVideoExportError.readerFailed(reader.error?.localizedDescription ?? "Unknown error"), writer: writer)
                    return
                }

                guard let sample = videoOutput.copyNextSampleBuffer() else {
                    videoInput.markAsFinished()
                    group.finish()
                    return
                }

                guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample),
                      let pool = adaptor.pixelBufferPool else {
                    videoInput.markAsFinished()
                    group.fail(SubtitleCompositorError.outputPoolUnavailable, writer: writer)
                    return
                }

                var outputBuffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer) == kCVReturnSuccess,
                      let outputBuffer else {
                    videoInput.markAsFinished()
                    group.fail(SubtitleCompositorError.pixelBufferCreationFailed, writer: writer)
                    return
                }

                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
                let seconds = presentationTime.seconds.isFinite ? presentationTime.seconds : 0
                let cue = cueCursor.activeCue(at: seconds, cues: sortedCues)

                do {
                    try compositor.render(
                        sourcePixelBuffer: sourceBuffer,
                        outputPixelBuffer: outputBuffer,
                        cue: cue,
                        renderSize: renderSize,
                        preferredTransform: preferredTransform,
                        sourceDisplaySize: sourceDisplaySize
                    )
                } catch {
                    videoInput.markAsFinished()
                    group.fail(error, writer: writer)
                    return
                }

                guard adaptor.append(outputBuffer, withPresentationTime: presentationTime) else {
                    videoInput.markAsFinished()
                    group.fail(HardSubtitleVideoExportError.writerFailed(writer.error?.localizedDescription ?? "Unknown error"), writer: writer)
                    return
                }

                let videoProgressScale = audioPipes.isEmpty ? 1.0 : 0.96
                let fraction = min(max(seconds / durationSeconds, 0), 1) * videoProgressScale
                Task { @MainActor in
                    progress(fraction)
                }
            }
        }
    }
}

nonisolated final class FFmpegVideoWriteContext: @unchecked Sendable {
    private let videoReader: FFmpegVideoExportVideoReader
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let writer: AVAssetWriter
    private let compositor: MetalSubtitleCompositor
    private let sortedCues: [ResolvedSubtitleCue]
    private let cueCursor: SubtitleCueCursor
    private let renderSize: CGSize
    private let sourceDisplaySize: CGSize?
    private let frameDuration: CMTime
    private let durationSeconds: Double
    private let progress: @MainActor @Sendable (Double) -> Void
    private let group: MediaWriteGroup
    private let videoState: FFmpegVideoWriteState
    private let hasAudio: Bool
    private let audioWriteContext: FFmpegAudioWriteContext?

    init(
        videoReader: FFmpegVideoExportVideoReader,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        writer: AVAssetWriter,
        compositor: MetalSubtitleCompositor,
        sortedCues: [ResolvedSubtitleCue],
        cueCursor: SubtitleCueCursor,
        renderSize: CGSize,
        sourceDisplaySize: CGSize?,
        frameDuration: CMTime,
        durationSeconds: Double,
        progress: @MainActor @Sendable @escaping (Double) -> Void,
        group: MediaWriteGroup,
        videoState: FFmpegVideoWriteState,
        hasAudio: Bool,
        audioWriteContext: FFmpegAudioWriteContext?
    ) {
        self.videoReader = videoReader
        self.videoInput = videoInput
        self.adaptor = adaptor
        self.writer = writer
        self.compositor = compositor
        self.sortedCues = sortedCues
        self.cueCursor = cueCursor
        self.renderSize = renderSize
        self.sourceDisplaySize = sourceDisplaySize
        self.frameDuration = frameDuration
        self.durationSeconds = durationSeconds
        self.progress = progress
        self.group = group
        self.videoState = videoState
        self.hasAudio = hasAudio
        self.audioWriteContext = audioWriteContext
    }

    func start(queue: DispatchQueue) {
        videoInput.requestMediaDataWhenReady(on: queue) { [self] in
            while videoInput.isReadyForMoreMediaData, !group.hasFailed {
                do {
                    guard let frame = try videoReader.nextFrame() else {
                        videoInput.markAsFinished()
                        if hasAudio {
                            audioWriteContext?.start(offset: 0)
                        }
                        group.finish()
                        return
                    }

                    let basePTS = videoState.basePTS(for: frame.pts)
                    audioWriteContext?.start(offset: basePTS)
                    let seconds = videoState.adjustedSeconds(for: frame.pts, basePTS: basePTS, frameDuration: frameDuration)

                    guard let pool = adaptor.pixelBufferPool else {
                        videoInput.markAsFinished()
                        group.fail(SubtitleCompositorError.outputPoolUnavailable, writer: writer)
                        return
                    }

                    var outputBuffer: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer) == kCVReturnSuccess,
                          let outputBuffer else {
                        videoInput.markAsFinished()
                        group.fail(SubtitleCompositorError.pixelBufferCreationFailed, writer: writer)
                        return
                    }

                    let cue = cueCursor.activeCue(at: seconds, cues: sortedCues)
                    try compositor.render(
                        sourcePixelBuffer: frame.pixelBuffer,
                        outputPixelBuffer: outputBuffer,
                        cue: cue,
                        renderSize: renderSize,
                        preferredTransform: .identity,
                        sourceDisplaySize: sourceDisplaySize
                    )

                    let presentationTime = CMTime(seconds: seconds, preferredTimescale: videoInput.mediaTimeScale)
                    guard adaptor.append(outputBuffer, withPresentationTime: presentationTime) else {
                        videoInput.markAsFinished()
                        group.fail(HardSubtitleVideoExportError.writerFailed(writer.error?.localizedDescription ?? "Unknown error"), writer: writer)
                        return
                    }
                    videoState.setLastVideoPresentationTime(presentationTime)

                    let videoProgressScale = hasAudio ? 0.96 : 1.0
                    let fraction = min(max(seconds / durationSeconds, 0), 1) * videoProgressScale
                    Task { @MainActor in
                        progress(fraction)
                    }
                } catch {
                    videoInput.markAsFinished()
                    group.fail(error, writer: writer)
                    return
                }
            }
        }
    }
}

nonisolated final class MediaWriteCancelContext: @unchecked Sendable {
    private let reader: AVAssetReader?
    private let writer: AVAssetWriter
    private let group: MediaWriteGroup

    init(reader: AVAssetReader? = nil, writer: AVAssetWriter, group: MediaWriteGroup) {
        self.reader = reader
        self.writer = writer
        self.group = group
    }

    func cancel() {
        reader?.cancelReading()
        writer.cancelWriting()
        group.fail(HardSubtitleVideoExportError.cancelled)
    }
}
