//
//  SubtitleProject.swift
//  SwiftSub
//
//  Created by Antigravity on 2026/5/16.
//

import Foundation
import Combine
import CoreGraphics

extension Notification.Name {
    static let subtitleProjectDidChange = Notification.Name("com.strophe.subtitleProjectDidChange")
}

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
    
    @Published var projectURL: URL?
    @Published private(set) var isDirty: Bool = false
    @Published private(set) var documentName: String = ""
    @Published var mediaLoadError: String? = nil
    
    private var autoSaveTimer: Timer?
    private var dirtyObserver: Any?
    private var mediaAccessURL: URL?
    private var projectURLBookmark: Data?
    
    init() {
        setupDirtyTracking()
    }
    
    private func setupDirtyTracking() {
        dirtyObserver = NotificationCenter.default.addObserver(
            forName: .subtitleProjectDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isDirty = true
            }
        }
    }
    
    func notifyChange() {
        NotificationCenter.default.post(name: .subtitleProjectDidChange, object: nil)
    }
    
    func markClean() {
        isDirty = false
    }
    
    @Published var videoURL: URL? {
        willSet {
            // Clean up the previous temporary directory/file if it was created by us
            if let oldURL = videoURL, oldURL.path.contains(NSTemporaryDirectory()) {
                let parentDir = oldURL.deletingLastPathComponent()
                try? FileManager.default.removeItem(at: parentDir)
            }
            // Stop and release the active engine when URL is about to change or clear
            activeEngine?.stop()
            activeEngine = nil
        }
        didSet {
            currentTime = 0 // Reset time on new video
            if let url = videoURL {
                // If it is already in our temporary directory, process waveform immediately
                if url.path.contains(NSTemporaryDirectory()) {
                    WaveformProcessor.shared.process(url: url) { data in
                        self.waveformData = data
                    }
                    notifyChange()
                    return
                }
                
                // If this URL already has security scope (restored from bookmark),
                // use it directly without creating symlink
                if mediaAccessURL == url {
                    WaveformProcessor.shared.process(url: url) { data in
                        self.waveformData = data
                    }
                    notifyChange()
                    return
                }
                
                // For regular file imports, create symlink to temp directory
                // to guarantee read permissions for background threads in sandboxed environment
                let tempDir = FileManager.default.temporaryDirectory
                let uniqueSubdir = tempDir.appendingPathComponent(UUID().uuidString)
                try? FileManager.default.createDirectory(at: uniqueSubdir, withIntermediateDirectories: true)
                let tempURL = uniqueSubdir.appendingPathComponent(url.lastPathComponent)
                
                do {
                    try FileManager.default.createSymbolicLink(at: tempURL, withDestinationURL: url)
                    self.videoURL = tempURL
                } catch {
                    print("Failed to create symlink to temp URL: \(error.localizedDescription)")
                    // Fallback to original URL if symlink fails
                    WaveformProcessor.shared.process(url: url) { data in
                        self.waveformData = data
                    }
                }
            }
            notifyChange()
        }
    }
    @Published var waveformData: WaveformData?
    @Published var videoFrameRate: Double = 30.0
    @Published var isAudioOnly: Bool = false
    @Published var videoSize: CGSize = .zero
    
    // Persistent player engine reference to survive SwiftUI layout identity resets
    var activeEngine: (any PlayerEngine)? = nil
    
    func snapToFrame(_ time: Double) -> Double {
        guard videoFrameRate > 0 else { return time }
        let frameDuration = 1.0 / videoFrameRate
        return (time / frameDuration).rounded() * frameDuration
    }

    func resnapAllItems() {
        for index in items.indices {
            if let start = items[index].startTime {
                items[index].startTime = snapToFrame(start)
            }
            if let end = items[index].endTime {
                items[index].endTime = snapToFrame(end)
            }
        }
        sortItemsStable()
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
    
    @Published var activeDragDelta: Double = 0
    @Published var activeDragItemID: UUID? = nil
    
    // MARK: - JK Slapping State
    @Published var activeSlapKey: String? = nil
    @Published var activeSlapSubtitleID: UUID? = nil
    
    func importScript(_ text: String) {
        let (hasTimeline, blocks) = SubtitleEngine.parseAnyText(text)

        self.items = blocks.enumerated().map { index, block in
            SubtitleItem(
                id: block.id,
                text: block.text,
                startTime: hasTimeline ? snapToFrame(block.startTime) : nil,
                endTime: hasTimeline ? snapToFrame(block.endTime) : nil,
                originalIndex: index
            )
        }
        self.currentIndex = 0
        notifyChange()
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
        notifyChange()
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
        notifyChange()
    }
    
    func updateSubtitleTime(id: UUID, newStartTime: TimeInterval, newEndTime: TimeInterval) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            let snappedStart = snapToFrame(max(0, newStartTime))
            let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
            let snappedEnd = snapToFrame(max(newStartTime + minDuration, newEndTime))
            items[index].startTime = snappedStart
            items[index].endTime = snappedEnd
            sortItemsStable()
            notifyChange()
        }
    }

    func moveSelectedBlocks(by delta: TimeInterval) {
        guard !selectedIDs.isEmpty else { return }
        for id in selectedIDs {
            if let index = items.firstIndex(where: { $0.id == id }),
               let start = items[index].startTime,
               let end = items[index].endTime {
                let newStart = snapToFrame(max(0, start + delta))
                let minDuration = videoFrameRate > 0 ? (1.0 / videoFrameRate) : 0.1
                let newEnd = snapToFrame(max(newStart + minDuration, end + delta))
                items[index].startTime = newStart
                items[index].endTime = newEnd
            }
        }
        sortItemsStable()
        notifyChange()
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
        notifyChange()
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
        notifyChange()
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
        notifyChange()
    }
    
    func deleteSubtitle(id: UUID) {
        items.removeAll(where: { $0.id == id })
        notifyChange()
    }
    
    func deleteSubtitles(ids: Set<UUID>) {
        items.removeAll(where: { ids.contains($0.id) })
        notifyChange()
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
    
    // MARK: - .strophe Project Persistence
    
    func prepareMediaAccess(for url: URL) {
        mediaAccessURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() {
            mediaAccessURL = url
        }
    }
    
    func replaceMedia(with url: URL) {
        mediaLoadError = nil
        prepareMediaAccess(for: url)
        videoURL = url
    }
    
    func resetForNewMedia() {
        items = []
        currentIndex = 0
        scrollTargetID = nil
        selectedIDs = []
        isEditingText = false
        currentTime = 0
        videoFrameRate = 30.0
        videoSize = .zero
        isAudioOnly = false
        showSoftSubtitles = false
        editingMode = .selection
        projectURL = nil
        documentName = ""
        mediaLoadError = nil
        projectURLBookmark = nil
        markClean()
    }
    
    var stropheDocument: StropheProjectDocument {
        var media: StropheProjectData.StropheMedia? = nil
        if let videoURL = videoURL {
            let originalURL = resolveOriginalURL(videoURL)
            let bookmark = createSecurityScopedBookmark(for: originalURL)
            media = StropheProjectData.StropheMedia(originalURL: originalURL, bookmark: bookmark)
        }
        let metadata = StropheProjectData.StropheMetadata(
            videoFrameRate: videoFrameRate,
            videoSize: videoSize != .zero ? StropheProjectData.StropheVideoSize(width: videoSize.width, height: videoSize.height) : nil,
            isAudioOnly: isAudioOnly,
            showSoftSubtitles: showSoftSubtitles,
            editingModeRaw: editingMode.rawValue,
            currentTime: currentTime,
            createdAt: Date(),
            modifiedAt: Date()
        )
        let data = StropheProjectData(version: 1, metadata: metadata, media: media, items: items)
        return StropheProjectDocument(data: data)
    }
    
    func saveStrophe(to url: URL) async throws {
        let data = stropheDocument.data
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let encoded = try encoder.encode(data)
        
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        
        try encoded.write(to: url)
        projectURL = url
        documentName = url.deletingPathExtension().lastPathComponent
        projectURLBookmark = createProjectURLBookmark(url)
        markClean()
    }
    
    func loadStrophe(from url: URL) async throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let rawData = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(StropheProjectData.self, from: rawData)
        
        guard decoded.version == 1 else {
            throw NSError(domain: "Strophe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported project version"])
        }
        
        items = decoded.items
        videoFrameRate = decoded.metadata.videoFrameRate
        if let sz = decoded.metadata.videoSize {
            videoSize = CGSize(width: sz.width, height: sz.height)
        }
        isAudioOnly = decoded.metadata.isAudioOnly
        showSoftSubtitles = decoded.metadata.showSoftSubtitles
        editingMode = decoded.metadata.editingMode
        currentTime = 0
        currentIndex = 0
        
        projectURL = url
        documentName = url.deletingPathExtension().lastPathComponent
        projectURLBookmark = createProjectURLBookmark(url)
        
        mediaLoadError = nil
        
        if let media = decoded.media {
            let mediaName = media.originalURL?.lastPathComponent ?? "media file"
            if let resolvedURL = resolveMediaURL(media: media) {
                videoURL = resolvedURL
            } else {
                mediaLoadError = mediaName
            }
        }
        
        markClean()
    }
    
    private func resolveMediaURL(media: StropheProjectData.StropheMedia) -> URL? {
        if let bookmark = media.bookmark, bookmark.count > 64 {
            if let resolved = resolveSecurityScopedBookmark(bookmark) {
                if resolved.startAccessingSecurityScopedResource() {
                    mediaAccessURL?.stopAccessingSecurityScopedResource()
                    mediaAccessURL = resolved
                }
                return resolved
            }
        }
        if let originalURL = media.originalURL {
            let resolved = originalURL.resolvingSymlinksInPath()
            if FileManager.default.fileExists(atPath: resolved.path) {
                return originalURL
            }
            print("⚠️ Original file not found at: \(resolved.path)")
        }
        return nil
    }
    
    private func resolveOriginalURL(_ url: URL) -> URL {
        if url.path.contains(NSTemporaryDirectory()) {
            let resolved = url.resolvingSymlinksInPath()
            if resolved != url {
                return resolved
            }
        }
        return url
    }
    
    private func createSecurityScopedBookmark(for url: URL) -> Data? {
        let resolvedURL = url.resolvingSymlinksInPath()
        #if os(macOS)
        guard let bookmark = try? resolvedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            print("⚠️ Failed to create bookmark for: \(resolvedURL.path)")
            return nil
        }
        var isStale = false
        guard (try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)) != nil else {
            print("⚠️ Created bookmark is invalid for: \(resolvedURL.path)")
            return nil
        }
        return bookmark
        #else
        return nil
        #endif
    }
    
    private func resolveSecurityScopedBookmark(_ bookmark: Data) -> URL? {
        #if os(macOS)
        var isStale = false
        if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            if isStale {
                print("⚠️ Bookmark is stale")
            }
            return resolved
        }
        #endif
        return nil
    }
    
    private func createProjectURLBookmark(_ url: URL) -> Data? {
        #if os(macOS)
        return try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return nil
        #endif
    }
    
    // MARK: - Auto Save
    
    func startAutoSave() {
        stopAutoSave()
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performAutoSave()
            }
        }
    }
    
    func stopAutoSave() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
    }
    
    func performAutoSave() async {
        guard isDirty, let url = projectURL else { return }
        
        var resolvedURL: URL?
        var didAccess = false
        
        if let bookmark = projectURLBookmark {
            if let resolved = resolveSecurityScopedBookmark(bookmark) {
                resolvedURL = resolved
                didAccess = resolved.startAccessingSecurityScopedResource()
            }
        }
        
        defer {
            if didAccess, let resolved = resolvedURL {
                resolved.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            let data = stropheDocument.data
            let encoder = JSONEncoder()
            let encoded = try encoder.encode(data)
            try encoded.write(to: resolvedURL ?? url)
            markClean()
        } catch {
            print("⚠️ Auto-save failed: \(error.localizedDescription)")
        }
    }
    
    var documentDisplayName: String {
        if !documentName.isEmpty { return documentName }
        if let videoURL = videoURL {
            return videoURL.deletingPathExtension().lastPathComponent
        }
        return ""
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
    
    // MARK: - Direct Playback Control Actions
    
    func togglePlayback() {
        guard let eng = activeEngine else { return }
        if eng.rate == 0 {
            eng.rate = targetSpeed
            playbackRate = 0.0
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
}
