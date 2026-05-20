//
//  SubtitleProject+Persistence.swift
//  Strophe
//
//  Project persistence and auto-save functionality
//

import Foundation
import CoreGraphics

extension SubtitleProject {
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
        setDocumentName(url.deletingPathExtension().lastPathComponent)
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
        setDocumentName(url.deletingPathExtension().lastPathComponent)
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
        return try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
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
