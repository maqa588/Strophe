//
//  SubtitleProject.swift
//  SwiftSub
//
//  Created by Antigravity on 2026/5/16.
//

import Foundation
import Combine

@MainActor
class SubtitleProject: ObservableObject {
    @Published var items: [SubtitleItem] = []
    @Published var currentIndex: Int = 0
    @Published var scrollTargetID: UUID? = nil
    @Published var showSoftSubtitles: Bool = false
    @Published var isSeeking: Bool = false
    @Published var editingMode: TimelineEditingMode = .selection
    @Published var selectedIDs: Set<UUID> = []
    @Published var isEditingText: Bool = false
    @Published var videoURL: URL? {
        willSet {
            // Clean up the previous temporary directory/file if it was created by us
            if let oldURL = videoURL, oldURL.path.contains(NSTemporaryDirectory()) {
                let parentDir = oldURL.deletingLastPathComponent()
                try? FileManager.default.removeItem(at: parentDir)
            }
        }
        didSet {
            currentTime = 0 // Reset time on new video
            if let url = videoURL {
                // If it is already in our temporary directory, process waveform immediately
                if url.path.contains(NSTemporaryDirectory()) {
                    WaveformProcessor.shared.process(url: url) { data in
                        self.waveformData = data
                    }
                    return
                }
                
                // Copy to temp directory to guarantee read permissions for background threads in sandboxed environment
                let tempDir = FileManager.default.temporaryDirectory
                let uniqueSubdir = tempDir.appendingPathComponent(UUID().uuidString)
                try? FileManager.default.createDirectory(at: uniqueSubdir, withIntermediateDirectories: true)
                let tempURL = uniqueSubdir.appendingPathComponent(url.lastPathComponent)
                
                let isScoped = url.startAccessingSecurityScopedResource()
                defer {
                    if isScoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                
                do {
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    self.videoURL = tempURL
                } catch {
                    print("Failed to copy media to temp URL: \(error.localizedDescription)")
                    // Fallback to original URL if copy fails
                    WaveformProcessor.shared.process(url: url) { data in
                        self.waveformData = data
                    }
                }
            }
        }
    }
    @Published var waveformData: WaveformData?
    @Published var videoFrameRate: Double = 30.0
    @Published var isAudioOnly: Bool = false
    
    func snapToFrame(_ time: Double) -> Double {
        guard videoFrameRate > 0 else { return time }
        let frameDuration = 1.0 / videoFrameRate
        return (time / frameDuration).rounded() * frameDuration
    }
    
    @Published var currentTime: Double = 0 {
        didSet {
            updateActiveSlapBlock(currentTime: currentTime)
            autoUpdateCurrentIndex()
        }
    }
    @Published var isScrubbing: Bool = false
    @Published var isUserSeekingTimeline: Bool = false
    @Published var playbackRate: Double = 0
    @Published var targetSpeed: Double = 1.0
    @Published var referenceTime: Double = 0
    @Published var referenceDate: Date = .now
    
    // MARK: - JK Slapping State
    @Published var activeSlapKey: String? = nil
    @Published var activeSlapSubtitleID: UUID? = nil
    
    func importScript(_ text: String) {
        let (hasTimeline, blocks) = SubtitleEngine.parseAnyText(text)
        
        self.items = blocks.enumerated().map { index, block in
            SubtitleItem(
                id: block.id,
                text: block.text,
                startTime: hasTimeline ? block.startTime : nil,
                endTime: hasTimeline ? block.endTime : nil,
                originalIndex: index
            )
        }
        self.currentIndex = 0
    }
    
    func markCurrentTime(_ time: TimeInterval) {
        guard currentIndex < items.count else { return }
        
        let snappedTime = snapToFrame(time)
        items[currentIndex].startTime = snappedTime
        
        if currentIndex > 0 && items[currentIndex - 1].endTime == nil {
            items[currentIndex - 1].endTime = snappedTime
        }
        
        if currentIndex < items.count - 1 {
            currentIndex += 1
        }
    }
    
    func stepBack() {
        if currentIndex > 0 {
            currentIndex -= 1
        }
    }
    
    // MARK: - Interactive Editing (Creation Mode)
    
    func createSubtitleBlock(startTime: TimeInterval, endTime: TimeInterval) {
        let snappedStart = snapToFrame(startTime)
        let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
        let snappedEnd = snapToFrame(max(startTime + minDuration, endTime))
        
        // 自动从上到下消耗未打轴的文稿
        if let index = items.firstIndex(where: { $0.startTime == nil }) {
            items[index].startTime = snappedStart
            items[index].endTime = snappedEnd
        } else {
            let newBlock = SubtitleItem(text: String(localized: "待录入字幕"), startTime: snappedStart, endTime: snappedEnd, originalIndex: items.count)
            items.append(newBlock)
        }
        
        sortItemsStable()
    }
    
    func updateSubtitleTime(id: UUID, newStartTime: TimeInterval, newEndTime: TimeInterval) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            let snappedStart = snapToFrame(max(0, newStartTime))
            let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
            let snappedEnd = snapToFrame(max(newStartTime + minDuration, newEndTime))
            items[index].startTime = snappedStart
            items[index].endTime = snappedEnd
            sortItemsStable()
        }
    }
    
    // MARK: - J/K Slapping Mode Handlers
    
    func handleSlapKeyDown(key: String) {
        // 避免键盘重复按键事件
        if activeSlapKey == key {
            return
        }
        
        // 如果另一个按键正在打轴中，先结算另一个
        if let currentActiveKey = activeSlapKey, currentActiveKey != key {
            finalizeActiveSlapBlock()
        }
        
        let startTime = snapToFrame(currentTime)
        let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
        let endTime = startTime + minDuration
        
        if let index = items.firstIndex(where: { $0.startTime == nil }) {
            items[index].startTime = startTime
            items[index].endTime = endTime
            activeSlapSubtitleID = items[index].id
        } else {
            let newID = UUID()
            let newBlock = SubtitleItem(id: newID, text: String(localized: "待录入字幕"), startTime: startTime, endTime: endTime, originalIndex: items.count)
            items.append(newBlock)
            activeSlapSubtitleID = newID
        }
        
        activeSlapKey = key
        sortItemsStable()
    }
    
    func handleSlapKeyUp(key: String) {
        if activeSlapKey == key {
            finalizeActiveSlapBlock()
        }
    }
    
    func finalizeActiveSlapBlock() {
        guard let id = activeSlapSubtitleID else { return }
        if let index = items.firstIndex(where: { $0.id == id }) {
            let start = items[index].startTime ?? 0
            let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
            items[index].endTime = snapToFrame(max(start + minDuration, currentTime))
        }
        activeSlapKey = nil
        activeSlapSubtitleID = nil
        
        sortItemsStable()
    }
    
    private func updateActiveSlapBlock(currentTime: TimeInterval) {
        guard let id = activeSlapSubtitleID else { return }
        if let index = items.firstIndex(where: { $0.id == id }) {
            let start = items[index].startTime ?? 0
            let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
            items[index].endTime = snapToFrame(max(start + minDuration, currentTime))
        }
    }
    
    func autoUpdateCurrentIndex() {
        var targetIndex: Int = 0
        var targetID: UUID? = nil
        
        if let activeID = activeSlapSubtitleID {
            if let index = items.firstIndex(where: { $0.id == activeID }) {
                targetIndex = index
                targetID = activeID
            }
        } else if let index = items.firstIndex(where: {
            if let start = $0.startTime, let end = $0.endTime {
                return currentTime >= start && currentTime <= end
            }
            return false
        }) {
            targetIndex = index
            targetID = items[index].id
        } else if let index = items.firstIndex(where: { $0.startTime == nil }) {
            targetIndex = index
            targetID = items[index].id
        } else if !items.isEmpty {
            targetIndex = 0
            targetID = items[0].id
        }
        
        // Prevent layout thrashing: only publish changes if the values have actually changed
        if currentIndex != targetIndex {
            currentIndex = targetIndex
        }
        if scrollTargetID != targetID {
            scrollTargetID = targetID
        }
    }
    
    func sortItemsStable() {
        items.sort { a, b in
            switch (a.startTime, b.startTime) {
            case let (startA?, startB?):
                return startA < startB
            case (_?, nil):
                return true  // 已打轴的排在前面
            case (nil, _?):
                return false // 未打轴的排在后面
            case (nil, nil):
                return a.originalIndex < b.originalIndex // 未打轴的保持导入时的原有顺序
            }
        }
        autoUpdateCurrentIndex()
    }
    
    func updateSubtitleText(id: UUID, text: String) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].text = text
        }
    }
    
    func deleteSubtitle(id: UUID) {
        items.removeAll(where: { $0.id == id })
    }
    
    func deleteSubtitles(ids: Set<UUID>) {
        items.removeAll(where: { ids.contains($0.id) })
    }
    
    // MARK: - Persistence
    
    func save(to url: URL) throws {
        let data = SubtitleProjectData(items: items, videoURL: videoURL)
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(data)
        try encoded.write(to: url)
    }
    
    func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SubtitleProjectData.self, from: data)
        self.items = decoded.items
        self.videoURL = decoded.videoURL
        self.currentIndex = 0
    }
    
    // MARK: - Export
    
    func generateSRT() -> String {
        var srt = ""
        for (index, item) in items.enumerated() {
            guard let start = item.startTime, let end = item.endTime ?? item.startTime?.advanced(by: 2.0) else { continue }
            
            srt += "\(index + 1)\n"
            srt += "\(formatTime(start)) --> \(formatTime(end))\n"
            srt += "\(item.text)\n\n"
        }
        return srt
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let totalMs = Int(seconds * 1000)
        let ms = totalMs % 1000
        let s = (totalMs / 1000) % 60
        let m = (totalMs / (1000 * 60)) % 60
        let h = totalMs / (1000 * 60 * 60)
        
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
    
    // MARK: - Overlap Detection and Computation
    
    struct OverlapInterval: Hashable {
        let start: TimeInterval
        let end: TimeInterval
    }
    
    func isItemOverlapping(id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }),
              let start = item.startTime,
              let end = item.endTime else { return false }
        
        for other in items {
            guard other.id != id,
                  let oStart = other.startTime,
                  let oEnd = other.endTime else { continue }
            
            if start < oEnd && oStart < end {
                return true
            }
        }
        return false
    }
    
    var overlappingIntervals: [OverlapInterval] {
        var intervals: [OverlapInterval] = []
        let timed = items.filter { $0.startTime != nil && $0.endTime != nil }
        guard timed.count > 1 else { return [] }
        
        for i in 0..<timed.count {
            for j in (i+1)..<timed.count {
                let a = timed[i]
                let b = timed[j]
                let startA = a.startTime!
                let endA = a.endTime!
                let startB = b.startTime!
                let endB = b.endTime!
                
                let overlapStart = max(startA, startB)
                let overlapEnd = min(endA, endB)
                
                if overlapStart < overlapEnd {
                    intervals.append(OverlapInterval(start: overlapStart, end: overlapEnd))
                }
            }
        }
        
        return mergeIntervals(intervals)
    }
    
    private func mergeIntervals(_ list: [OverlapInterval]) -> [OverlapInterval] {
        guard list.count > 1 else { return list }
        let sorted = list.sorted { $0.start < $1.start }
        var merged: [OverlapInterval] = []
        var current = sorted[0]
        
        for next in sorted[1...] {
            if next.start <= current.end {
                current = OverlapInterval(start: current.start, end: max(current.end, next.end))
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }
}
