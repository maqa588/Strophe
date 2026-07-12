//
//  SubtitleProject+Playback.swift
//  Strophe
//
//  Direct playback control actions
//

import Foundation
import Combine

extension SubtitleProject {
    enum SubtitleBoundaryDirection {
        case left
        case right
    }

    func togglePlayback() {
        guard let eng = activeEngine else { return }
        if eng.rate == 0 {
            eng.rate = targetSpeed
            playbackRate = targetSpeed
            referenceTime = eng.currentTime
            referenceDate = .now
        } else {
            eng.rate = 0.0
            playbackRate = 0.0
            referenceTime = eng.currentTime
            referenceDate = .now
        }
    }
    
    func pause() {
        guard let eng = activeEngine else { return }
        if eng.rate != 0 {
            eng.rate = 0.0
            playbackRate = 0.0
            referenceTime = eng.currentTime
            referenceDate = .now
        }
    }
    
    func seekDelta(_ delta: Double) {
        guard let eng = activeEngine else { return }
        guard !isSeeking else { return }
        
        let currentTimeVal = eng.currentTime
        let durationVal = eng.duration
        let targetTime = max(0, (durationVal.isNaN || durationVal <= 0) ? currentTimeVal + delta : min(durationVal, currentTimeVal + delta))

        isSeeking = true
        Task { @MainActor in
            let finished = await eng.seek(to: targetTime)
            isSeeking = false
            let resolvedTime = eng.currentTime
            if finished, resolvedTime.isFinite {
                self.currentTime = resolvedTime
                self.referenceTime = resolvedTime
            } else {
                syncPlaybackClockFromEngine()
            }
            self.referenceDate = .now
        }
    }

    func seekToSubtitleBoundary(_ direction: SubtitleBoundaryDirection) {
        guard let targetTime = subtitleBoundaryTarget(from: currentTime, direction: direction) else { return }
        seekTimelineImmediately(to: targetTime, exact: false)
    }

    func seekByFrames(_ frameCount: Int) {
        guard frameCount != 0 else { return }
        let fps = videoFrameRate.isFinite && videoFrameRate > 0 ? videoFrameRate : 30.0
        let targetTime = currentTime + Double(frameCount) / fps
        seekTimelineImmediately(to: targetTime, exact: true)
    }

    private func subtitleBoundaryTarget(from time: Double, direction: SubtitleBoundaryDirection) -> Double? {
        let frameTolerance = videoFrameRate > 0 ? (1.0 / videoFrameRate) * 0.5 : 0.001
        let edgeTolerance = max(frameTolerance, 0.001)

        switch direction {
        case .left:
            let starts = timelineIndex.itemsByStartTime
                .compactMap(\.startTime)
                .filter(\.isFinite)
            return starts.last(where: { $0 < time - edgeTolerance })

        case .right:
            let ends = timelineIndex.itemsByStartTime
                .compactMap { item -> Double? in
                    guard let start = item.startTime else { return nil }
                    return item.endTime ?? start
                }
                .filter(\.isFinite)
                .sorted()
            return ends.first(where: { $0 > time + edgeTolerance })
        }
    }

    private func seekTimelineImmediately(to time: Double, exact: Bool) {
        let duration = activeEngine?.duration ?? 0
        let targetTime = max(0, (duration.isFinite && duration > 0) ? min(duration, time) : time)

        subtitleBoundarySeekGeneration &+= 1
        let generation = subtitleBoundarySeekGeneration
        subtitleBoundarySeekTask?.cancel()

        objectWillChange.send()
        currentTime = targetTime
        referenceTime = targetTime
        referenceDate = .now

        guard let eng = activeEngine else {
            isSeeking = false
            return
        }

        isSeeking = true
        subtitleBoundarySeekTask = Task { @MainActor in
            let finished = if exact {
                await eng.seekExactly(to: targetTime)
            } else {
                await eng.seek(to: targetTime)
            }
            guard subtitleBoundarySeekGeneration == generation else { return }
            isSeeking = false
            let resolvedTime = eng.currentTime
            if finished, resolvedTime.isFinite {
                currentTime = resolvedTime
                referenceTime = resolvedTime
            } else {
                syncPlaybackClockFromEngine()
            }
            referenceDate = .now
        }
    }
    
    func changePlaybackSpeed(_ speed: Double) {
        targetSpeed = speed
        let isPlaying = activeEngine?.rate != 0 || playbackRate != 0
        if isPlaying {
            activeEngine?.rate = speed
        }
        playbackRate = isPlaying ? speed : 0.0
        referenceTime = activeEngine?.currentTime ?? 0
        referenceDate = .now
    }

    func syncPlaybackClockFromEngine() {
        guard let eng = activeEngine else { return }
        let engineTime = eng.currentTime
        guard engineTime.isFinite else { return }
        currentTime = engineTime
        referenceTime = engineTime
        referenceDate = .now
        playbackRate = eng.rate
    }

    func seek(to time: Double) {
        guard let eng = activeEngine else {
            self.currentTime = time
            self.referenceTime = time
            self.referenceDate = .now
            return
        }
        guard !isSeeking else { return }
        
        isSeeking = true
        Task { @MainActor in
            let finished = await eng.seek(to: time)
            isSeeking = false
            let resolvedTime = eng.currentTime
            if finished, resolvedTime.isFinite {
                self.currentTime = resolvedTime
                self.referenceTime = resolvedTime
            } else {
                syncPlaybackClockFromEngine()
            }
            self.referenceDate = .now
        }
    }
}
