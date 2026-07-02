//
//  SubtitleProject+Persistence.swift
//  Strophe
//
//  Project persistence and auto-save functionality
//

import Foundation
import CoreGraphics

extension SubtitleProject {
    func importMedia(from url: URL) {
        pause()
        if items.isEmpty {
            resetForNewMedia()
            prepareMediaAccess(for: url)
            videoURL = url
        } else {
            replaceMedia(with: url)
        }
    }

    func importMediaAsNewProject(from url: URL) {
        pause()
        stopAutoSave()
        resetForNewMedia()
        setDocumentName(url.deletingPathExtension().lastPathComponent)

        if let cacheURL = cachedProjectURL(for: url) {
            projectURL = cacheURL
            projectURLBookmark = nil
        }

        prepareMediaAccess(for: url)
        videoURL = url

        if let cacheURL = projectURL {
            Task { @MainActor in
                try? await saveStrophe(to: cacheURL)
                startAutoSave()
            }
        }
    }
    
    func importStropheProject(from url: URL) async throws {
        try await loadStrophe(from: url)
        startAutoSave()
    }

    func importStropheDocument(_ document: StropheProjectDocument, from url: URL?, startsAutoSave: Bool) async throws {
        try await loadStropheData(document.data, from: url)
        if startsAutoSave {
            startAutoSave()
        } else {
            stopAutoSave()
        }
    }

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
        isSubtitleMultiSelecting = false
        isEditingText = false
        currentTime = 0
        videoFrameRate = 30.0
        videoSize = .zero
        isAudioOnly = false
        showSoftSubtitles = false
        editingMode = .selection
        projectURL = nil
        setDocumentName("")
        mediaLoadError = nil
        projectURLBookmark = nil
        waveformData = nil
        markClean()
    }

    private func cachedProjectURL(for mediaURL: URL) -> URL? {
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }

        let projectCacheDirectory = cachesURL
            .appendingPathComponent("Strophe", isDirectory: true)
            .appendingPathComponent("ProjectCache", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: projectCacheDirectory, withIntermediateDirectories: true)
        } catch {
            print("⚠️ Failed to create project cache directory: \(error.localizedDescription)")
            return nil
        }

        let baseName = mediaURL.deletingPathExtension().lastPathComponent
        let fileName = baseName.isEmpty ? "Untitled.strophe" : "\(baseName).strophe"
        return projectCacheDirectory.appendingPathComponent(fileName)
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
        let defaultTrack = StropheTrack(
            id: UUID(),
            name: "Default Track",
            language: nil,
            isEnabled: true,
            items: items,
            parentTrackID: nil,
            trackType: .primary
        )
        let data = StropheProjectData(
            version: 1,
            metadata: metadata,
            media: media,
            tracks: [defaultTrack],
            styles: [],
            subgroupStyles: StyleAndGroupStore.shared.storedStyles(),
            subtitleGroups: StyleAndGroupStore.shared.storedGroups()
        )
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
        setDocumentName(url.deletingPathExtension().lastPathComponent)
        projectURLBookmark = createProjectURLBookmark(url)
        markClean()
    }
    
    func loadStrophe(from url: URL) async throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let decoded = try await Task.detached(priority: .userInitiated) {
            let rawData = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(StropheProjectData.self, from: rawData)
        }.value

        try await loadStropheData(decoded, from: url)
    }

    func loadStropheData(_ decoded: StropheProjectData, from url: URL?) async throws {
        guard decoded.version == 1 else {
            throw NSError(domain: "Strophe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported project version"])
        }
        
        // Reset old project state first, which stops activeEngine, resets videoURL to nil, clears waveformData, etc.
        resetForNewMedia()
        videoURL = nil
        
        items = decoded.items
        StyleAndGroupStore.shared.restore(styles: decoded.subgroupStyles, groups: decoded.subtitleGroups)
        videoFrameRate = decoded.metadata.videoFrameRate
        if let sz = decoded.metadata.videoSize {
            videoSize = CGSize(width: sz.width, height: sz.height)
        }
        isAudioOnly = decoded.metadata.isAudioOnly
        showSoftSubtitles = decoded.metadata.showSoftSubtitles
        editingMode = decoded.metadata.editingMode
        currentTime = 0
        currentIndex = 0
        
        if decoded.metadata.currentTime > 0.1 {
            loadedPlayheadTime = decoded.metadata.currentTime
        } else {
            loadedPlayheadTime = nil
        }
        
        projectURL = url
        if let url {
            setDocumentName(url.deletingPathExtension().lastPathComponent)
            projectURLBookmark = createProjectURLBookmark(url)
        } else {
            setDocumentName("")
            projectURLBookmark = nil
        }
        
        mediaLoadError = nil
        
        if let media = decoded.media {
            let mediaName = media.originalURL?.lastPathComponent ?? "media file"
            if let resolvedURL = resolveMediaURL(media: media) {
                videoURL = resolvedURL
            } else {
                videoURL = nil
                mediaLoadError = mediaName
            }
        } else {
            videoURL = nil
        }
        
        markClean()
    }
    
    func resolveMediaURL(media: StropheProjectData.StropheMedia) -> URL? {
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
    
    func resolveOriginalURL(_ url: URL) -> URL {
        if url.path.contains(NSTemporaryDirectory()) {
            let resolved = url.resolvingSymlinksInPath()
            if resolved != url {
                return resolved
            }
        }
        return url
    }
    
    func createSecurityScopedBookmark(for url: URL) -> Data? {
        let resolvedURL = url.resolvingSymlinksInPath()
        #if os(macOS)
        let didAccess = resolvedURL.startAccessingSecurityScopedResource()
        defer { if didAccess { resolvedURL.stopAccessingSecurityScopedResource() } }
        let bookmark: Data
        do {
            bookmark = try resolvedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            print("⚠️ Failed to create bookmark for: \(resolvedURL.path) — \(error.localizedDescription)")
            return nil
        }
        var isStale = false
        do {
            _ = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
        } catch {
            print("⚠️ Created bookmark is invalid for: \(resolvedURL.path) — \(error.localizedDescription)")
            return nil
        }
        return bookmark
        #else
        return nil
        #endif
    }
    
    func resolveSecurityScopedBookmark(_ bookmark: Data) -> URL? {
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
    
    func createProjectURLBookmark(_ url: URL) -> Data? {
        #if os(macOS)
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            print("⚠️ Failed to create project bookmark for: \(url.path) — \(error.localizedDescription)")
            return nil
        }
        #else
        return nil
        #endif
    }
    
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
        if resolvedURL == nil {
            resolvedURL = url
            didAccess = url.startAccessingSecurityScopedResource()
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
    
    func generateSRT() -> String {
        var srt = ""
        for (index, item) in items.enumerated() {
            guard let start = item.startTime, let end = item.endTime ?? item.startTime?.advanced(by: 2.0) else { continue }
            
            srt += "\(index + 1)\n"
            srt += "\(formatSRTTime(start)) --> \(formatSRTTime(end))\n"
            srt += "\(item.text)\n\n"
        }
        return srt
    }
    
    private func formatSRTTime(_ seconds: TimeInterval) -> String {
        let totalMs = Int(seconds * 1000)
        let ms = totalMs % 1000
        let s = (totalMs / 1000) % 60
        let m = (totalMs / (1000 * 60)) % 60
        let h = totalMs / (1000 * 60 * 60)
        
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
