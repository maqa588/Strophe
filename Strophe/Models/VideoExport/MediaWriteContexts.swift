//
//  MediaWriteContexts.swift
//  Strophe
//
//  Created by Antigravity on 2026/06/04.
//

import AVFoundation
import CoreImage
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

nonisolated struct FFmpegAudioPipe: @unchecked Sendable {
    let reader: FFmpegVideoExportAudioReader
    let input: AVAssetWriterInput
}

/// Retains both IOSurfaces until Core Image's GPU fence completes. Frames are
/// appended in presentation order even though several renders may be in flight.
nonisolated struct PendingRenderedVideoFrame: @unchecked Sendable {
    let sourcePixelBuffer: CVPixelBuffer
    let outputPixelBuffer: CVPixelBuffer
    let renderTask: CIRenderTask?
    let presentationTime: CMTime
    let progressSeconds: Double

    func waitUntilRendered() throws {
        if let renderTask {
            _ = try renderTask.waitUntilCompleted()
        }
    }
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

/// Coalesces frame-level progress into UI-sized updates. Export may process
/// hundreds of frames per second, while the progress view only needs a few
/// updates per second.
nonisolated final class ExportProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumInterval: CFTimeInterval
    private let progress: @MainActor @Sendable (Double) -> Void
    private var lastUpdateTime: CFTimeInterval = 0
    private var lastProgress: Double = 0

    init(
        minimumInterval: CFTimeInterval = 0.1,
        progress: @MainActor @Sendable @escaping (Double) -> Void
    ) {
        self.minimumInterval = minimumInterval
        self.progress = progress
    }

    func report(_ rawProgress: Double) {
        let value = min(max(rawProgress, 0), 1)
        let now = CFAbsoluteTimeGetCurrent()
        let shouldReport = lock.withLock {
            guard value >= lastProgress,
                lastUpdateTime == 0 || now - lastUpdateTime >= minimumInterval
            else {
                return false
            }
            lastProgress = value
            lastUpdateTime = now
            return true
        }
        guard shouldReport else { return }

        Task { @MainActor [progress] in
            progress(value)
        }
    }
}

nonisolated final class SubtitleSceneCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var nextIndex: Int
    private var active: [ResolvedSubtitleCue] = []
    private var lastTime = -Double.infinity

    init(index: Int = 0) {
        nextIndex = index
    }

    func activeCues(
        at seconds: Double,
        cues: [ResolvedSubtitleCue]
    ) -> [ResolvedSubtitleCue] {
        lock.withLock {
            guard seconds.isFinite else { return [] }
            if seconds < lastTime {
                nextIndex = 0
                active.removeAll(keepingCapacity: true)
            }
            lastTime = seconds

            while nextIndex < cues.count,
                cues[nextIndex].startTime <= seconds
            {
                let cue = cues[nextIndex]
                if cue.endTime > seconds {
                    active.append(cue)
                }
                nextIndex += 1
            }
            active.removeAll { $0.endTime <= seconds }
            return active
        }
    }
}

nonisolated final class FFmpegVideoWriteState: @unchecked Sendable {
    private let lock = NSLock()
    private var firstVideoPTS: Double?
    private var lastScheduledPresentationTime = CMTime.invalid
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

    func reservePresentationTime(
        for framePTS: Double,
        basePTS: Double,
        frameDuration: CMTime,
        timescale: CMTimeScale
    ) -> CMTime {
        lock.withLock {
            var seconds = max(0, framePTS - basePTS)
            if lastScheduledPresentationTime.isValid {
                let minimumNextSeconds = CMTimeAdd(
                    lastScheduledPresentationTime,
                    frameDuration
                ).seconds
                if minimumNextSeconds.isFinite,
                    seconds <= lastScheduledPresentationTime.seconds
                {
                    seconds = minimumNextSeconds
                }
            }
            let presentationTime = CMTime(
                seconds: seconds,
                preferredTimescale: timescale
            )
            lastScheduledPresentationTime = presentationTime
            return presentationTime
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
    private let startGate = OnceGate()

    init(
        audioReader: FFmpegVideoExportAudioReader,
        audioInput: AVAssetWriterInput,
        writer: AVAssetWriter,
        group: MediaWriteGroup,
        queue: DispatchQueue
    ) {
        self.audioReader = audioReader
        self.audioInput = audioInput
        self.writer = writer
        self.group = group
        self.queue = queue
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
                            self.group.fail(
                                HardSubtitleVideoExportError.audioMuxFailed(
                                    self.writer.error?.localizedDescription ?? "Unknown error"), writer: self.writer)
                            return
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
    private let cueCursor: SubtitleSceneCursor
    private let collisionMode: SubtitleCollisionMode
    private let renderSize: CGSize
    private let preferredTransform: CGAffineTransform
    private let sourceDisplaySize: CGSize?
    private let timelineStartSeconds: Double
    private let durationSeconds: Double
    private let allowsDirectFramePassThrough: Bool
    private let directPassThroughPixelFormat: OSType
    private let maxInFlightFrames: Int
    private let progressReporter: ExportProgressReporter
    private let group: MediaWriteGroup
    private var pendingFrames: [PendingRenderedVideoFrame] = []
    private var reachedVideoEnd = false
    private var didFinishVideo = false

    init(
        reader: AVAssetReader,
        videoOutput: AVAssetReaderTrackOutput,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        audioPipes: [AudioPipe],
        writer: AVAssetWriter,
        compositor: MetalSubtitleCompositor,
        sortedCues: [ResolvedSubtitleCue],
        cueCursor: SubtitleSceneCursor,
        collisionMode: SubtitleCollisionMode,
        renderSize: CGSize,
        preferredTransform: CGAffineTransform,
        sourceDisplaySize: CGSize?,
        timelineStartSeconds: Double,
        durationSeconds: Double,
        allowsDirectFramePassThrough: Bool,
        directPassThroughPixelFormat: OSType,
        maxInFlightFrames: Int,
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
        self.collisionMode = collisionMode
        self.renderSize = renderSize
        self.preferredTransform = preferredTransform
        self.sourceDisplaySize = sourceDisplaySize
        self.timelineStartSeconds = timelineStartSeconds
        self.durationSeconds = durationSeconds
        self.allowsDirectFramePassThrough = allowsDirectFramePassThrough
        self.directPassThroughPixelFormat = directPassThroughPixelFormat
        self.maxInFlightFrames = max(1, maxInFlightFrames)
        progressReporter = ExportProgressReporter(progress: progress)
        self.group = group
    }

    func start(
        videoQueue: DispatchQueue,
        audioQueues: [DispatchQueue]
    ) {
        for (pipe, audioQueue) in zip(audioPipes, audioQueues) {
            pipe.input.requestMediaDataWhenReady(on: audioQueue) { [self] in
                while pipe.input.isReadyForMoreMediaData, !group.hasFailed {
                    if reader.status == .failed {
                        pipe.input.markAsFinished()
                        group.fail(
                            HardSubtitleVideoExportError.readerFailed(
                                reader.error?.localizedDescription ?? "Unknown error"), writer: writer)
                        return
                    }

                    guard let sample = pipe.output.copyNextSampleBuffer() else {
                        pipe.input.markAsFinished()
                        group.finish()
                        return
                    }

                    guard pipe.input.append(sample) else {
                        pipe.input.markAsFinished()
                        group.fail(
                            HardSubtitleVideoExportError.audioMuxFailed(
                                writer.error?.localizedDescription ?? "Unknown error"), writer: writer)
                        return
                    }
                }
            }
        }

        videoInput.requestMediaDataWhenReady(on: videoQueue) { [self] in
            while videoInput.isReadyForMoreMediaData,
                !group.hasFailed,
                !didFinishVideo
            {
                do {
                    while pendingFrames.count < maxInFlightFrames,
                        !reachedVideoEnd
                    {
                        try enqueueNextFrame()
                    }

                    guard !pendingFrames.isEmpty else {
                        finishVideoIfReady()
                        return
                    }

                    try appendFirstPendingFrame()
                    finishVideoIfReady()
                } catch {
                    videoInput.markAsFinished()
                    group.fail(error, writer: writer)
                    return
                }
            }
        }
    }

    private func enqueueNextFrame() throws {
        if reader.status == .failed {
            throw HardSubtitleVideoExportError.readerFailed(
                reader.error?.localizedDescription ?? "Unknown error"
            )
        }
        guard let sample = videoOutput.copyNextSampleBuffer() else {
            reachedVideoEnd = true
            return
        }
        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else {
            throw SubtitleCompositorError.outputPoolUnavailable
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
        let seconds =
            presentationTime.seconds.isFinite
            ? presentationTime.seconds
            : 0
        let activeCues = cueCursor.activeCues(at: seconds, cues: sortedCues)
        let scene = compositor.makeFrameScene(
            cues: activeCues,
            at: seconds,
            renderSize: renderSize,
            collisionMode: collisionMode
        )
        if canPassThrough(sourceBuffer, scene: scene) {
            pendingFrames.append(
                PendingRenderedVideoFrame(
                    sourcePixelBuffer: sourceBuffer,
                    outputPixelBuffer: sourceBuffer,
                    renderTask: nil,
                    presentationTime: presentationTime,
                    progressSeconds: seconds
                )
            )
            return
        }

        guard let pool = adaptor.pixelBufferPool else {
            throw SubtitleCompositorError.outputPoolUnavailable
        }
        var outputBuffer: CVPixelBuffer?
        guard
            CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pool,
                &outputBuffer
            ) == kCVReturnSuccess,
            let outputBuffer
        else {
            throw SubtitleCompositorError.pixelBufferCreationFailed
        }
        let renderTask = try compositor.startRender(
            sourcePixelBuffer: sourceBuffer,
            outputPixelBuffer: outputBuffer,
            scene: scene,
            renderSize: renderSize,
            preferredTransform: preferredTransform,
            sourceDisplaySize: sourceDisplaySize
        )
        pendingFrames.append(
            PendingRenderedVideoFrame(
                sourcePixelBuffer: sourceBuffer,
                outputPixelBuffer: outputBuffer,
                renderTask: renderTask,
                presentationTime: presentationTime,
                progressSeconds: seconds
            )
        )
    }

    private func canPassThrough(
        _ sourceBuffer: CVPixelBuffer,
        scene: SubtitleFrameScene
    ) -> Bool {
        allowsDirectFramePassThrough
            && scene.items.isEmpty
            && CVPixelBufferGetPixelFormatType(sourceBuffer)
                == directPassThroughPixelFormat
            && CVPixelBufferGetWidth(sourceBuffer) == Int(renderSize.width)
            && CVPixelBufferGetHeight(sourceBuffer) == Int(renderSize.height)
    }

    private func appendFirstPendingFrame() throws {
        let pending = pendingFrames.removeFirst()
        try pending.waitUntilRendered()
        guard
            adaptor.append(
                pending.outputPixelBuffer,
                withPresentationTime: pending.presentationTime
            )
        else {
            throw HardSubtitleVideoExportError.writerFailed(
                writer.error?.localizedDescription ?? "Unknown error"
            )
        }

        let videoProgressScale = audioPipes.isEmpty ? 1.0 : 0.99
        let elapsed = max(0, pending.progressSeconds - timelineStartSeconds)
        let fraction =
            min(max(elapsed / durationSeconds, 0), 1)
            * videoProgressScale
        progressReporter.report(fraction)
    }

    private func finishVideoIfReady() {
        guard reachedVideoEnd,
            pendingFrames.isEmpty,
            !didFinishVideo
        else {
            return
        }
        didFinishVideo = true
        videoInput.markAsFinished()
        group.finish()
    }
}

nonisolated final class FFmpegVideoWriteContext: @unchecked Sendable {
    private let videoReader: FFmpegVideoExportVideoReader
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let writer: AVAssetWriter
    private let compositor: MetalSubtitleCompositor
    private let sortedCues: [ResolvedSubtitleCue]
    private let cueCursor: SubtitleSceneCursor
    private let collisionMode: SubtitleCollisionMode
    private let renderSize: CGSize
    private let sourceDisplaySize: CGSize?
    private let frameDuration: CMTime
    private let sourceRange: Range<Double>?
    private let durationSeconds: Double
    private let allowsDirectFramePassThrough: Bool
    private let directPassThroughPixelFormat: OSType
    private let maxInFlightFrames: Int
    private let progressReporter: ExportProgressReporter
    private let group: MediaWriteGroup
    private let videoState: FFmpegVideoWriteState
    private let hasAudio: Bool
    private let audioWriteContexts: [FFmpegAudioWriteContext]
    private var pendingFrames: [PendingRenderedVideoFrame] = []
    private var reachedVideoEnd = false
    private var didFinishVideo = false

    init(
        videoReader: FFmpegVideoExportVideoReader,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        writer: AVAssetWriter,
        compositor: MetalSubtitleCompositor,
        sortedCues: [ResolvedSubtitleCue],
        cueCursor: SubtitleSceneCursor,
        collisionMode: SubtitleCollisionMode,
        renderSize: CGSize,
        sourceDisplaySize: CGSize?,
        frameDuration: CMTime,
        sourceRange: Range<Double>?,
        durationSeconds: Double,
        allowsDirectFramePassThrough: Bool,
        directPassThroughPixelFormat: OSType,
        maxInFlightFrames: Int,
        progress: @MainActor @Sendable @escaping (Double) -> Void,
        group: MediaWriteGroup,
        videoState: FFmpegVideoWriteState,
        audioWriteContexts: [FFmpegAudioWriteContext]
    ) {
        self.videoReader = videoReader
        self.videoInput = videoInput
        self.adaptor = adaptor
        self.writer = writer
        self.compositor = compositor
        self.sortedCues = sortedCues
        self.cueCursor = cueCursor
        self.collisionMode = collisionMode
        self.renderSize = renderSize
        self.sourceDisplaySize = sourceDisplaySize
        self.frameDuration = frameDuration
        self.sourceRange = sourceRange
        self.durationSeconds = durationSeconds
        self.allowsDirectFramePassThrough = allowsDirectFramePassThrough
        self.directPassThroughPixelFormat = directPassThroughPixelFormat
        self.maxInFlightFrames = max(1, maxInFlightFrames)
        progressReporter = ExportProgressReporter(progress: progress)
        self.group = group
        self.videoState = videoState
        self.hasAudio = !audioWriteContexts.isEmpty
        self.audioWriteContexts = audioWriteContexts
    }

    func start(queue: DispatchQueue) {
        videoInput.requestMediaDataWhenReady(on: queue) { [self] in
            while videoInput.isReadyForMoreMediaData,
                !group.hasFailed,
                !didFinishVideo
            {
                do {
                    while pendingFrames.count < maxInFlightFrames,
                        !reachedVideoEnd
                    {
                        try enqueueNextFrame()
                    }

                    guard !pendingFrames.isEmpty else {
                        finishVideoIfReady()
                        return
                    }

                    try appendFirstPendingFrame()
                    finishVideoIfReady()
                } catch {
                    videoInput.markAsFinished()
                    group.fail(error, writer: writer)
                    return
                }
            }
        }
    }

    private func enqueueNextFrame() throws {
        while true {
            guard let frame = try videoReader.nextFrame() else {
                reachedVideoEnd = true
                startAudioIfNeeded(fallbackOffset: sourceRange?.lowerBound ?? 0)
                return
            }

            if let sourceRange, frame.pts < sourceRange.lowerBound {
                continue
            }
            if let sourceRange, frame.pts >= sourceRange.upperBound {
                reachedVideoEnd = true
                startAudioIfNeeded(fallbackOffset: sourceRange.lowerBound)
                return
            }

            let basePTS = videoState.basePTS(for: frame.pts)
            let audioOffset = sourceRange?.lowerBound ?? basePTS
            startAudioIfNeeded(fallbackOffset: audioOffset)
            let presentationTime = videoState.reservePresentationTime(
                for: frame.pts,
                basePTS: basePTS,
                frameDuration: frameDuration,
                timescale: videoInput.mediaTimeScale
            )

            let activeCues = cueCursor.activeCues(
                at: frame.pts,
                cues: sortedCues
            )
            let scene = compositor.makeFrameScene(
                cues: activeCues,
                at: frame.pts,
                renderSize: renderSize,
                collisionMode: collisionMode
            )
            if canPassThrough(frame.pixelBuffer, scene: scene) {
                pendingFrames.append(
                    PendingRenderedVideoFrame(
                        sourcePixelBuffer: frame.pixelBuffer,
                        outputPixelBuffer: frame.pixelBuffer,
                        renderTask: nil,
                        presentationTime: presentationTime,
                        progressSeconds: presentationTime.seconds
                    )
                )
                return
            }

            guard let pool = adaptor.pixelBufferPool else {
                throw SubtitleCompositorError.outputPoolUnavailable
            }
            var outputBuffer: CVPixelBuffer?
            guard
                CVPixelBufferPoolCreatePixelBuffer(
                    nil,
                    pool,
                    &outputBuffer
                ) == kCVReturnSuccess,
                let outputBuffer
            else {
                throw SubtitleCompositorError.pixelBufferCreationFailed
            }
            let renderTask = try compositor.startRender(
                sourcePixelBuffer: frame.pixelBuffer,
                outputPixelBuffer: outputBuffer,
                scene: scene,
                renderSize: renderSize,
                preferredTransform: .identity,
                sourceDisplaySize: sourceDisplaySize
            )
            pendingFrames.append(
                PendingRenderedVideoFrame(
                    sourcePixelBuffer: frame.pixelBuffer,
                    outputPixelBuffer: outputBuffer,
                    renderTask: renderTask,
                    presentationTime: presentationTime,
                    progressSeconds: presentationTime.seconds
                )
            )
            return
        }
    }

    private func canPassThrough(
        _ sourceBuffer: CVPixelBuffer,
        scene: SubtitleFrameScene
    ) -> Bool {
        allowsDirectFramePassThrough
            && scene.items.isEmpty
            && CVPixelBufferGetPixelFormatType(sourceBuffer)
                == directPassThroughPixelFormat
            && CVPixelBufferGetWidth(sourceBuffer) == Int(renderSize.width)
            && CVPixelBufferGetHeight(sourceBuffer) == Int(renderSize.height)
    }

    private func appendFirstPendingFrame() throws {
        let pending = pendingFrames.removeFirst()
        try pending.waitUntilRendered()
        guard
            adaptor.append(
                pending.outputPixelBuffer,
                withPresentationTime: pending.presentationTime
            )
        else {
            throw HardSubtitleVideoExportError.writerFailed(
                writer.error?.localizedDescription ?? "Unknown error"
            )
        }
        videoState.setLastVideoPresentationTime(pending.presentationTime)

        let videoProgressScale = hasAudio ? 0.99 : 1.0
        let fraction =
            min(
                max(pending.progressSeconds / durationSeconds, 0),
                1
            ) * videoProgressScale
        progressReporter.report(fraction)
    }

    private func startAudioIfNeeded(fallbackOffset: Double) {
        guard hasAudio else { return }
        audioWriteContexts.forEach { $0.start(offset: fallbackOffset) }
    }

    private func finishVideoIfReady() {
        guard reachedVideoEnd,
            pendingFrames.isEmpty,
            !didFinishVideo
        else {
            return
        }
        didFinishVideo = true
        videoInput.markAsFinished()
        startAudioIfNeeded(fallbackOffset: sourceRange?.lowerBound ?? 0)
        group.finish()
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
