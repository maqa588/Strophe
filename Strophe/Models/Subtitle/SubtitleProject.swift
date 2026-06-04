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
    @Published var timelineIndex: TimelineIndex = TimelineIndex()
    @Published var items: [SubtitleItem] = [] {
        didSet {
            timelineIndex.rebuild(with: items)
        }
    }
    @Published var currentIndex: Int = 0
    @Published var scrollTargetID: UUID? = nil
    @Published var showSoftSubtitles: Bool = false {
        didSet {
            notifyChange()
        }
    }
    @Published var showHardSubtitles: Bool = false
    @Published var isSeeking: Bool = false
    @Published var editingMode: TimelineEditingMode = .selection
    @Published var selectedIDs: Set<UUID> = []
    @Published var isSubtitleMultiSelecting: Bool = false
    @Published var isEditingText: Bool = false
    @Published var subtitleClipboard: [SubtitleItem] = []
    
    @Published var projectURL: URL?
    @Published private(set) var isDirty: Bool = false
    @Published private(set) var documentName: String = ""
    @Published var mediaLoadError: String? = nil
    @Published var isLoadingProject: Bool = false
    
    let undoManager = UndoManager()
    
    var autoSaveTimer: Timer?
    var dirtyObserver: Any?
    var mediaAccessURL: URL?
    var projectURLBookmark: Data?
    
    init() {
        setupDirtyTracking()
    }
    
    private func setupDirtyTracking() {
        dirtyObserver = NotificationCenter.default.addObserver(
            forName: .subtitleProjectDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isDirty = true
            }
        }
    }
    
    func notifyChange() {
        isDirty = true
        NotificationCenter.default.post(name: .subtitleProjectDidChange, object: nil)
    }
    
    func markClean() {
        isDirty = false
    }
    
    func setDocumentName(_ name: String) {
        documentName = name
    }
    
    @Published var videoURL: URL? {
        willSet {
            if let oldURL = videoURL, oldURL.path.contains(NSTemporaryDirectory()) {
                let parentDir = oldURL.deletingLastPathComponent()
                try? FileManager.default.removeItem(at: parentDir)
            }
            activeEngine?.stop()
            activeEngine = nil
            waveformData?.cancelAllActiveTasks()
            waveformData = nil
        }
        didSet {
            currentTime = 0
            if let url = videoURL {
                if url.path.contains(NSTemporaryDirectory()) {
                    WaveformProcessor.shared.process(url: url) { data in
                        self.waveformData = data
                    }
                    notifyChange()
                    return
                }
                
                if mediaAccessURL == url {
                    WaveformProcessor.shared.process(url: url) { data in
                        self.waveformData = data
                    }
                    notifyChange()
                    return
                }
                
                let tempDir = FileManager.default.temporaryDirectory
                let uniqueSubdir = tempDir.appendingPathComponent(UUID().uuidString)
                try? FileManager.default.createDirectory(at: uniqueSubdir, withIntermediateDirectories: true)
                let tempURL = uniqueSubdir.appendingPathComponent(url.lastPathComponent)
                
                do {
                    try FileManager.default.createSymbolicLink(at: tempURL, withDestinationURL: url)
                    self.videoURL = tempURL
                } catch {
                    print("Failed to create symlink to temp URL: \(error.localizedDescription)")
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
    
    var currentTime: Double = 0 {
        didSet {
            guard currentTime.isFinite else {
                currentTime = oldValue.isFinite ? oldValue : 0
                referenceTime = currentTime
                referenceDate = .now
                return
            }
            updateActiveSlapBlock(currentTime: currentTime)
            autoUpdateCurrentIndex()
            if let wData = waveformData {
                let shouldLoadWaveformChunk = abs(wData.currentTime - currentTime) > 0.25 || isScrubbing
                wData.currentTime = currentTime
                if shouldLoadWaveformChunk {
                    wData.loadChunkIfNeeded(at: currentTime)
                }
            }
            if isScrubbing {
                NotificationCenter.default.post(name: .stropheScrubTimeChanged, object: currentTime)
            }
        }
    }
    @Published var isScrubbing: Bool = false
    @Published var isUserSeekingTimeline: Bool = false
    var playbackRate: Double = 0 {
        didSet {
            if oldValue != playbackRate {
                objectWillChange.send()
            }
        }
    }
    @Published var targetSpeed: Double = 1.0
    var referenceTime: Double = 0
    var referenceDate: Date = .now
    
    @Published var activeDragDelta: Double = 0
    @Published var activeDragItemID: UUID? = nil
    
    @Published var activeSlapKey: String? = nil
    @Published var activeSlapSubtitleID: UUID? = nil
    
    @Published var currentSubtitleText: String? = nil
    @Published var loadedPlayheadTime: Double? = nil
    
    func subtitleText(at time: Double) -> String? {
        if let activeID = activeSlapSubtitleID,
           let item = items.first(where: { $0.id == activeID }),
           !item.isHidden,
           subgroup(for: item)?.isOverlayEnabled != false {
            return item.text
        }

        let activeGroupID = StyleAndGroupStore.shared.activeGroupID
        return items
            .filter { item in
                guard !item.isHidden, subgroup(for: item)?.isOverlayEnabled != false else { return false }
                guard let start = item.startTime, let end = item.endTime else { return false }
                return time >= start && time <= end
            }
            .sorted { lhs, rhs in
                if lhs.groupID == activeGroupID && rhs.groupID != activeGroupID { return true }
                if lhs.groupID != activeGroupID && rhs.groupID == activeGroupID { return false }
                return lhs.trackIndex < rhs.trackIndex
            }
            .first?.text
    }
}
