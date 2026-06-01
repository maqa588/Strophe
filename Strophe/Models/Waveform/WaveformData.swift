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
    @Published var levels: [Int: [WaveformBin]] = [:]
    @Published var isProcessing: Bool = false
    @Published var progress: Double = 0
    
    @Published var duration: Double = 0
    @Published var sampleRate: Double = 44100
    
    // Chunk loading state
    var mediaURL: URL?
    var chunkDuration: Double = 10.0 // Optimized to 10 seconds per chunk for instant loading
    var loadedChunks: Set<Int> = []
    private var activeTasks: [Int: Task<Void, Never>] = [:]
    
    // Track playhead position to perform scrubbing task cancellation
    var currentTime: Double = 0.0
    
    // Track last time to distinguish seeks/jumps from normal play
    private var lastTriggerTime: Double = -999.0
    
    func cancelAllActiveTasks() {
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
        
        let totalSamples = Int(duration * sampleRate)
        for zoom in WaveformProcessor.zoomLevels {
            let count = totalSamples / zoom
            self.levels[zoom] = Array(repeating: WaveformBin(peakPositive: 0, peakNegative: 0, rms: 0), count: count)
        }
        
        // Fast path for high-speed local storage: sequential single-pass AVFoundation decoding
        var isLocal = true
        if url.isFileURL {
            if let resourceValues = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
               let local = resourceValues.volumeIsLocal {
                isLocal = local
            }
        } else {
            isLocal = false
        }
        
        let isCompatible = FormatDetector.shared.cachedResult(for: url)?.isAVFoundationCompatible 
            ?? ["mp4", "m4a", "mov", "mp3", "wav", "caf", "aif", "aiff"].contains(url.pathExtension.lowercased())
            
        if isLocal && isCompatible {
            loadLocalEntireFile(url: url)
        } else {
            loadChunkIfNeeded(at: 0.0)
        }
    }
    
    private func loadLocalEntireFile(url: URL) {
        guard activeTasks[-1] == nil else { return }
        
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            let success = await WaveformProcessor.shared.decodeEntireFileViaAVFoundation(url: url) { [weak self] samples, chunkStart, chunkDur in
                guard let self = self else { return }
                Task { @MainActor in
                    self.updateLevels(with: samples, index: 0, chunkStart: chunkStart, chunkDur: chunkDur)
                    
                    // Mark all covered 10-second chunks as loaded
                    let startChunk = Int(chunkStart / self.chunkDuration)
                    let endChunk = Int(ceil((chunkStart + chunkDur) / self.chunkDuration))
                    for i in startChunk..<endChunk {
                        self.loadedChunks.insert(i)
                    }
                    
                    let totalChunksCount = Int(ceil(self.duration / self.chunkDuration))
                    self.progress = Double(self.loadedChunks.count) / Double(totalChunksCount > 0 ? totalChunksCount : 1)
                }
            }
            
            await MainActor.run {
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
        
        let chunkIndex = Int(time / chunkDuration)
        let totalChunks = Int(ceil(duration / chunkDuration))
        guard chunkIndex >= 0 && chunkIndex < totalChunks else { return }
        
        // Detect a seek/jump
        let isJump = abs(time - lastTriggerTime) > 5.0
        lastTriggerTime = time
        
        if isJump {
            // User jumped! Cancel ALL active tasks immediately to reclaim disk I/O
            for (_, task) in activeTasks {
                // print("🛑 WaveformProcessor: Jump detected. Cancelling task for chunk \(idx)") // Uncomment to debug waveform tasks
                task.cancel()
            }
            activeTasks.removeAll()
        } else {
            // Normal play/idle: cancel tasks that are far behind the playhead (more than 30s behind)
            let staleKeys = activeTasks.keys.filter { idx in
                let chunkStart = Double(idx) * chunkDuration
                return chunkStart < (time - 30.0)
            }
            for idx in staleKeys {
                if let task = activeTasks.removeValue(forKey: idx) {
                    // print("🛑 WaveformProcessor: Playback advanced. Cancelling stale past task for chunk \(idx)") // Uncomment to debug waveform tasks
                    task.cancel()
                }
            }
        }
        
        // To guarantee zero disk I/O contention and perfect playback smoothness,
        // we enforce that at most ONE waveform decoding task runs at any given time.
        guard activeTasks.isEmpty else { return }
        
        // 1. Prioritized immediate window loading:
        // We define the immediate window indices in order of strict priority.
        let immediatePrioritized = [
            chunkIndex,             // 1st Priority: Current playhead chunk
            chunkIndex + 1,         // 2nd Priority: Next chunk (about to play)
            chunkIndex - 1,         // 3rd Priority: Previous chunk (scrolling back)
            chunkIndex + 2          // 4th Priority: Chunk after next
        ]
        
        for idx in immediatePrioritized {
            guard idx >= 0 && idx < totalChunks else { continue }
            if !loadedChunks.contains(idx) {
                // print("🔥 WaveformProcessor: Prioritized loading chunk \(idx) at high priority") // Uncomment to debug waveform tasks
                loadChunk(index: idx, url: url, priority: .userInitiated)
                return // Only start ONE task!
            }
        }
        
        // 2. Continuous background pre-fetching:
        // If the immediate window is fully loaded, and we are playing or idle, pre-fetch subsequent chunks.
        let startSearchIndex = chunkIndex + 3
        if startSearchIndex < totalChunks {
            for idx in startSearchIndex..<totalChunks {
                if !loadedChunks.contains(idx) {
                    // print("🌾 WaveformProcessor: Background pre-fetching next unloaded chunk \(idx) ahead at low priority") // Uncomment to debug waveform tasks
                    loadChunk(index: idx, url: url, priority: .background)
                    return // Only start ONE task!
                }
            }
        }
    }
    
    private func loadChunk(index: Int, url: URL, priority: TaskPriority = .userInitiated) {
        guard !loadedChunks.contains(index) && activeTasks[index] == nil else { return }
        
        let chunkStart = Double(index) * chunkDuration
        let chunkDur = min(chunkDuration, duration - chunkStart)
        
        let task = Task.detached(priority: priority) { [weak self] in
            guard let self = self else { return }
            
            // For low-priority background tasks, add a brief delay to yield the CPU/IO resources
            if priority == .background {
                do {
                    try await Task.sleep(nanoseconds: 150_000_000) // 150ms delay
                } catch {
                    // Task was cancelled during sleep
                    await MainActor.run {
                        _ = self.activeTasks.removeValue(forKey: index)
                    }
                    return
                }
            }
            
            // Check cancellation before decoding
            if Task.isCancelled {
                await MainActor.run {
                    _ = self.activeTasks.removeValue(forKey: index)
                }
                return
            }
            
            // print("🔄 WaveformProcessor: Loading chunk \(index) (time: \(chunkStart)s to \(chunkStart + chunkDur)s at \(priority == .background ? "low" : "high") priority)") // Uncomment to debug waveform tasks
            if let samples = await WaveformProcessor.shared.decodeChunk(url: url, startTime: chunkStart, duration: chunkDur) {
                // Check cancellation after decoding
                if Task.isCancelled {
                    await MainActor.run {
                        _ = self.activeTasks.removeValue(forKey: index)
                    }
                    return
                }
                await MainActor.run {
                    self.updateLevels(with: samples, index: index, chunkStart: chunkStart, chunkDur: chunkDur)
                    self.loadedChunks.insert(index)
                    self.activeTasks.removeValue(forKey: index)
                    
                    let totalChunksCount = Int(ceil(self.duration / self.chunkDuration))
                    self.progress = Double(self.loadedChunks.count) / Double(totalChunksCount > 0 ? totalChunksCount : 1)
                    
                    // Maintain background loading chain
                    self.loadChunkIfNeeded(at: self.currentTime)
                }
            } else {
                let isCancelled = Task.isCancelled
                await MainActor.run {
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
    
    private func updateLevels(with samples: [Float], index: Int, chunkStart: Double, chunkDur: Double) {
        guard !samples.isEmpty else { return }
        
        for zoom in WaveformProcessor.zoomLevels {
            guard var mainBins = self.levels[zoom] else { continue }
            
            let startSample = Int(chunkStart * sampleRate)
            let endSample = Int((chunkStart + chunkDur) * sampleRate)
            
            let startBinIndex = startSample / zoom
            let endBinIndex = min(mainBins.count, endSample / zoom)
            let expectedBinCount = endBinIndex - startBinIndex
            
            guard expectedBinCount > 0 else { continue }
            
            let chunkBins = WaveformProcessor.computeBins(samples: samples, expectedBinCount: expectedBinCount)
            
            if startBinIndex >= 0 && startBinIndex + chunkBins.count <= mainBins.count {
                mainBins.replaceSubrange(startBinIndex..<(startBinIndex + chunkBins.count), with: chunkBins)
                self.levels[zoom] = mainBins
            }
        }
    }
}
