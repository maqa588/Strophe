//
//  WaveformData.swift
//  Strophe
//
//  Created by maqa on 2026/5/18.
//

import Foundation
import Combine
import AVFoundation

@MainActor
class WaveformData: ObservableObject {
    private(set) var levels: [Int: [WaveformBin]] = [:]
    @Published var isProcessing: Bool = false
    @Published var progress: Double = 0

    @Published var duration: Double = 0
    @Published var sampleRate: Double = 44100

    var mediaURL: URL?
    var chunkDuration: Double = 10.0
    var loadedChunks: Set<Int> = []
    private var activeTasks: [Int: Task<Void, Never>] = [:]
    private var taskGeneration: UInt = 0
    private var isRemoteMedia = false
    private var isPlaybackActive = false

    var currentTime: Double = 0.0

    private var lastTriggerTime: Double = -999.0

    func cancelAllActiveTasks() {
        taskGeneration &+= 1
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
    }

    func initialize(duration: Double, sampleRate: Double, url: URL) {
        cancelAllActiveTasks()

        self.duration = duration
        self.sampleRate = sampleRate
        self.mediaURL = url
        self.loadedChunks = []
        self.currentTime = 0.0
        self.lastTriggerTime = -999.0
        self.isRemoteMedia = FormatDetector.isRemoteNetworkVolume(url)
        self.isPlaybackActive = false

        let totalSamples = Int(duration * sampleRate)
        objectWillChange.send()
        for zoom in WaveformProcessor.zoomLevels {
            let count = totalSamples / zoom
            self.levels[zoom] = Array(repeating: WaveformBin(peakPositive: 0, peakNegative: 0, rms: 0), count: count)
        }

        // Fast path for high-speed local storage: sequential single-pass AVFoundation decoding
        let isCompatible =
            FormatDetector.shared.cachedResult(for: url)?.isAVFoundationCompatible
            ?? ["mp4", "m4a", "mov", "mp3", "wav", "caf", "aif", "aiff"].contains(url.pathExtension.lowercased())

        if !isRemoteMedia && isCompatible {
            loadLocalEntireFile(url: url)
        } else if isRemoteMedia {
            // Avoid racing the player's initial SMB probe/open. If playback has
            // started by the time this fires, setPlaybackActive cancels it.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard let self, !self.isPlaybackActive else { return }
                self.loadChunkIfNeeded(at: self.currentTime)
            }
        } else {
            loadChunkIfNeeded(at: 0.0)
        }
    }

    func setPlaybackActive(_ isActive: Bool) {
        guard isRemoteMedia, isPlaybackActive != isActive else { return }
        isPlaybackActive = isActive
        if isActive {
            // A second decoder seeking through the same SMB file can starve the
            // playback demuxer. Remote waveform work yields completely while
            // transport is running.
            cancelAllActiveTasks()
        } else {
            loadChunkIfNeeded(at: currentTime)
        }
    }

    private func loadLocalEntireFile(url: URL) {
        guard activeTasks[-1] == nil else { return }

        let rate = sampleRate
        let levelBinCounts = levels.mapValues(\.count)
        let generation = taskGeneration

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let priority: TaskPriority = fileSize >= 512 * 1_024 * 1_024 ? .utility : .userInitiated
        let task = Task.detached(priority: priority) { [weak self] in
            guard let self = self else { return }

            let success = await WaveformProcessor.shared.decodeEntireFileViaAVFoundation(url: url) {
                [weak self] samples, chunkStart, chunkDur in
                guard let self = self else { return }
                let patches = WaveformProcessor.computeLevelPatches(
                    samples: samples,
                    chunkStart: chunkStart,
                    chunkDuration: chunkDur,
                    sampleRate: rate,
                    levelBinCounts: levelBinCounts
                )
                Task { @MainActor in
                    guard self.taskGeneration == generation else { return }
                    self.applyLevelPatches(patches)

                    // Mark all covered 10-second chunks as loaded
                    let startChunk = Int(chunkStart / self.chunkDuration)
                    let endChunk = Int(ceil((chunkStart + chunkDur) / self.chunkDuration))
                    for i in startChunk..<endChunk {
                        self.loadedChunks.insert(i)
                    }

                    let totalChunksCount = Int(ceil(self.duration / self.chunkDuration))
                    self.progress =
                        Double(self.loadedChunks.count) / Double(totalChunksCount > 0 ? totalChunksCount : 1)
                }
            }

            await MainActor.run {
                guard self.taskGeneration == generation else { return }
                self.activeTasks.removeValue(forKey: -1)
                if success {
                    // Fast path complete: mark all chunks as loaded to prevent subsequent pre-fetches
                    let totalChunksCount = Int(ceil(self.duration / self.chunkDuration))
                    for i in 0..<totalChunksCount {
                        self.loadedChunks.insert(i)
                    }
                    self.progress = 1.0
                } else {
                    // Fallback to standard sliced loading on failure
                    self.loadChunkIfNeeded(at: self.currentTime)
                }
            }
        }
        activeTasks[-1] = task
    }

    func loadChunkIfNeeded(at time: Double) {
        guard let url = mediaURL, duration > 0 else { return }
        guard !isRemoteMedia || !isPlaybackActive else { return }

        let chunkIndex = Int(time / chunkDuration)
        let totalChunks = Int(ceil(duration / chunkDuration))
        guard chunkIndex >= 0 && chunkIndex < totalChunks else { return }

        // Detect a seek/jump
        let isJump = abs(time - lastTriggerTime) > 5.0
        lastTriggerTime = time

        if isJump {
            cancelAllActiveTasks()
        } else {
            // Normal play/idle: cancel tasks that are far behind the playhead (more than 30s behind)
            let staleKeys = activeTasks.keys.filter { idx in
                let chunkStart = Double(idx) * chunkDuration
                return chunkStart < (time - 30.0)
            }
            for idx in staleKeys {
                if let task = activeTasks.removeValue(forKey: idx) {
                    task.cancel()
                }
            }
        }

        // Limit waveform decoding to one task so it cannot contend with media playback.
        guard activeTasks.isEmpty else { return }

        // Load the playhead neighborhood in priority order.
        let immediatePrioritized =
            isRemoteMedia
            ? [chunkIndex]
            : [
                chunkIndex,
                chunkIndex + 1,
                chunkIndex - 1,
                chunkIndex + 2,
            ]

        for idx in immediatePrioritized {
            guard idx >= 0 && idx < totalChunks else { continue }
            if !loadedChunks.contains(idx) {
                loadChunk(index: idx, url: url, priority: .userInitiated)
                return
            }
        }

        // Never crawl through an entire remote file in the background. Each
        // chunk would reopen and seek the SMB stream, competing with playback.
        if isRemoteMedia { return }

        // Prefetch later local chunks after the immediate window is available.
        let startSearchIndex = chunkIndex + 3
        if startSearchIndex < totalChunks {
            for idx in startSearchIndex..<totalChunks {
                if !loadedChunks.contains(idx) {
                    loadChunk(index: idx, url: url, priority: .background)
                    return
                }
            }
        }
    }

    private func loadChunk(index: Int, url: URL, priority: TaskPriority = .userInitiated) {
        guard !loadedChunks.contains(index) && activeTasks[index] == nil else { return }

        let chunkStart = Double(index) * chunkDuration
        let chunkDur = min(chunkDuration, duration - chunkStart)
        let rate = sampleRate
        let levelBinCounts = levels.mapValues(\.count)
        let generation = taskGeneration

        let task = Task.detached(priority: priority) { [weak self] in
            guard let self = self else { return }

            if priority == .background {
                do {
                    try await Task.sleep(nanoseconds: 150_000_000)  // 150ms delay
                } catch {
                    await MainActor.run {
                        guard self.taskGeneration == generation else { return }
                        _ = self.activeTasks.removeValue(forKey: index)
                    }
                    return
                }
            }

            if Task.isCancelled {
                await MainActor.run {
                    guard self.taskGeneration == generation else { return }
                    _ = self.activeTasks.removeValue(forKey: index)
                }
                return
            }

            if let samples = await WaveformProcessor.shared.decodeChunk(
                url: url, startTime: chunkStart, duration: chunkDur)
            {
                if Task.isCancelled {
                    await MainActor.run {
                        guard self.taskGeneration == generation else { return }
                        _ = self.activeTasks.removeValue(forKey: index)
                    }
                    return
                }
                let patches = WaveformProcessor.computeLevelPatches(
                    samples: samples,
                    chunkStart: chunkStart,
                    chunkDuration: chunkDur,
                    sampleRate: rate,
                    levelBinCounts: levelBinCounts
                )
                if Task.isCancelled {
                    await MainActor.run {
                        guard self.taskGeneration == generation else { return }
                        _ = self.activeTasks.removeValue(forKey: index)
                    }
                    return
                }
                await MainActor.run {
                    guard self.taskGeneration == generation else { return }
                    self.applyLevelPatches(patches)
                    self.loadedChunks.insert(index)
                    self.activeTasks.removeValue(forKey: index)

                    let totalChunksCount = Int(ceil(self.duration / self.chunkDuration))
                    self.progress =
                        Double(self.loadedChunks.count) / Double(totalChunksCount > 0 ? totalChunksCount : 1)

                    // Maintain background loading chain
                    self.loadChunkIfNeeded(at: self.currentTime)
                }
            } else {
                let isCancelled = Task.isCancelled
                await MainActor.run {
                    guard self.taskGeneration == generation else { return }
                    self.activeTasks.removeValue(forKey: index)
                    if !isCancelled {
                        // Mark as loaded/failed so we skip it in subsequent pre-fetches
                        self.loadedChunks.insert(index)
                        // Maintain background loading chain on failure
                        self.loadChunkIfNeeded(at: self.currentTime)
                    }
                }
            }
        }
        activeTasks[index] = task
    }

    private func applyLevelPatches(_ patches: [WaveformProcessor.LevelPatch]) {
        guard !patches.isEmpty else { return }
        objectWillChange.send()
        for patch in patches {
            guard patch.startIndex >= 0,
                let mainBinCount = levels[patch.zoom]?.count,
                patch.startIndex + patch.bins.count <= mainBinCount
            else { continue }
            levels[patch.zoom]?.replaceSubrange(
                patch.startIndex..<(patch.startIndex + patch.bins.count),
                with: patch.bins
            )
        }
    }
}
