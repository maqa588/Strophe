//
//  SubtitleProject+Playback.swift
//  Strophe
//
//  Direct playback control actions
//

import Foundation

extension SubtitleProject {
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
            await eng.seek(to: targetTime)
            isSeeking = false
            self.currentTime = targetTime
            self.referenceTime = targetTime
            self.referenceDate = .now
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
            await eng.seek(to: time)
            isSeeking = false
            self.currentTime = time
            self.referenceTime = time
            self.referenceDate = .now
        }
    }
}
