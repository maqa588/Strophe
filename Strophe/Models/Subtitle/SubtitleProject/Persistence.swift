//
//  SubtitleProject+Persistence.swift
//  Strophe
//
//  Project persistence and auto-save functionality
//

import Foundation
import CoreGraphics

#if os(macOS)
private let bookmarkCreationOptions = URL.BookmarkCreationOptions.withSecurityScope
private let bookmarkResolutionOptions = URL.BookmarkResolutionOptions.withSecurityScope
#else
private let bookmarkCreationOptions = URL.BookmarkCreationOptions()
private let bookmarkResolutionOptions = URL.BookmarkResolutionOptions()
#endif

private nonisolated struct MediaFileProbeResult: Sendable {
    let resolvedURL: URL?
    let state: MediaAccessState
    let technicalMessage: String
}

private nonisolated func probeReadableMediaFile(at url: URL) -> MediaFileProbeResult {
    let fileManager = FileManager.default

    if fileManager.isUbiquitousItem(at: url) {
        do {
            try fileManager.startDownloadingUbiquitousItem(at: url)
        } catch {
            return MediaFileProbeResult(
                resolvedURL: nil,
                state: .unreadable,
                technicalMessage: "iCloud could not start downloading the selected media: \(error.localizedDescription)"
            )
        }
    }

    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var probeResult: MediaFileProbeResult?

    coordinator.coordinate(
        readingItemAt: url,
        options: .withoutChanges,
        error: &coordinationError
    ) { coordinatedURL in
        let resolvedURL = coordinatedURL.resolvingSymlinksInPath()
        do {
            let handle = try FileHandle(forReadingFrom: resolvedURL)
            try handle.close()
            probeResult = MediaFileProbeResult(
                resolvedURL: resolvedURL,
                state: .ready,
                technicalMessage: "The selected media file is ready."
            )
        } catch {
            let cocoaError = error as NSError
            let state: MediaAccessState =
                cocoaError.domain == NSCocoaErrorDomain
                && cocoaError.code == NSFileNoSuchFileError
                ? .missing
                : .permissionDenied
            probeResult = MediaFileProbeResult(
                resolvedURL: resolvedURL,
                state: state,
                technicalMessage: "The selected media could not be opened for reading: \(error.localizedDescription)"
            )
        }
    }

    if let coordinationError {
        let state: MediaAccessState =
            coordinationError.domain == NSCocoaErrorDomain
            && coordinationError.code == NSFileNoSuchFileError
            ? .missing
            : .unreadable
        return MediaFileProbeResult(
            resolvedURL: nil,
            state: state,
            technicalMessage: "File Provider could not prepare the selected media: \(coordinationError.localizedDescription)"
        )
    }

    return probeResult ?? MediaFileProbeResult(
        resolvedURL: nil,
        state: .unreadable,
        technicalMessage: "File Provider returned no readable media URL."
    )
}

extension SubtitleProject {
    func createNewProject() {
        pause()
        stopAutoSave()
        mediaAccessGeneration &+= 1
        mediaAccessURL?.stopAccessingSecurityScopedResource()
        mediaAccessURL = nil
        videoURL = nil
        resetForNewMedia()
    }

    func importMedia(from url: URL) async {
        pause()
        if items.isEmpty {
            resetForNewMedia()
            videoURL = nil
            if let preparedURL = await prepareMediaAccess(for: url) {
                videoURL = preparedURL
            }
        } else {
            await replaceMedia(with: url)
        }
    }

    func importMediaAsNewProject(from url: URL) async {
        pause()
        stopAutoSave()
        resetForNewMedia()
        setDocumentName(url.deletingPathExtension().lastPathComponent)

        videoURL = nil
        guard let preparedURL = await prepareMediaAccess(for: url) else { return }
        videoURL = preparedURL

        if let cacheURL = cachedProjectURL(for: url) {
            projectURL = cacheURL
            projectURLBookmark = nil
        }

        if let cacheURL = projectURL {
            Task { @MainActor in
                do {
                    try await saveStrophe(to: cacheURL)
                    // The file must exist before AppKit/security-scoped bookmark
                    // APIs are asked to add it to Recents.
                    WelcomeRecentProjectsStore.remember(cacheURL)
                    startAutoSave()
                } catch {
                    print("⚠️ Failed to create cached project: \(error.localizedDescription)")
                }
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
    
    @discardableResult
    func prepareMediaAccess(for url: URL) async -> URL? {
        mediaAccessGeneration &+= 1
        let generation = mediaAccessGeneration
        mediaAccessURL?.stopAccessingSecurityScopedResource()
        mediaAccessURL = nil
        mediaLoadError = nil
        mediaAccessStatus = MediaAccessStatus(
            state: .resolving,
            requestedURL: url,
            resolvedURL: nil,
            usesSecurityScope: false,
            technicalMessage: nil
        )

        print("📥 Preparing selected media: \(url.lastPathComponent)")
        let didAccess = url.startAccessingSecurityScopedResource()
        print("🔐 Media security scope \(didAccess ? "granted" : "not required") for \(url.lastPathComponent)")

        let probe = await Task.detached(priority: .userInitiated) {
            probeReadableMediaFile(at: url)
        }.value

        guard generation == mediaAccessGeneration else {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
            print("⚠️ Ignored stale media preparation result for \(url.lastPathComponent)")
            return nil
        }

        guard probe.state == .ready, let resolvedURL = probe.resolvedURL else {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
            mediaAccessStatus = MediaAccessStatus(
                state: probe.state,
                requestedURL: url,
                resolvedURL: probe.resolvedURL,
                usesSecurityScope: false,
                technicalMessage: probe.technicalMessage
            )
            mediaLoadError = url.lastPathComponent
            print("❌ Media preparation failed [\(probe.state.rawValue)]: \(probe.technicalMessage)")
            return nil
        }

        if didAccess {
            mediaAccessURL = url
        }
        mediaLoadError = nil
        mediaAccessStatus = .ready(
            requestedURL: url,
            resolvedURL: resolvedURL,
            usesSecurityScope: didAccess
        )
        print("✅ Media ready for playback: \(url.lastPathComponent)")
        return url
    }
    
    func replaceMedia(with url: URL) async {
        pause()
        videoURL = nil
        mediaLoadError = nil
        mediaAccessStatus = .none
        if let preparedURL = await prepareMediaAccess(for: url) {
            videoURL = preparedURL
        }
    }

    func reportMediaPlaybackFailure(
        for url: URL,
        state: MediaAccessState,
        technicalMessage: String
    ) {
        guard videoURL == url else { return }
        let originalURL = mediaAccessStatus.requestedURL ?? resolveOriginalURL(url)
        let resolvedURL = state == .missing ? nil : url.resolvingSymlinksInPath()
        mediaAccessStatus = MediaAccessStatus(
            state: state,
            requestedURL: originalURL,
            resolvedURL: resolvedURL,
            usesSecurityScope: mediaAccessURL != nil,
            technicalMessage: technicalMessage
        )
        mediaLoadError = originalURL.lastPathComponent
    }
    
    func resetForNewMedia() {
        items = []
        subtitleSourceDocuments = []
        lastSubtitleImportDiagnostics = []
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
        subtitleCollisionMode = .normal
        editingMode = .selection
        projectURL = nil
        setDocumentName("")
        mediaLoadError = nil
        projectURLBookmark = nil
        waveformData = nil
        markers = []
        inPoint = nil
        outPoint = nil
        loopsSelection = false
        projectIdentifier = UUID()
        projectCreatedAt = Date()
        markClean()
    }

    nonisolated static var projectCacheDirectoryURL: URL? {
        let fm = FileManager.default
        
        #if os(iOS)
        // On iOS devices, the cachesDirectory can be purged by the system when storage is low.
        // Therefore, we use applicationSupportDirectory to keep the project cache persistent.
        guard let baseDirectoryURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        // Migrate old caches if they exist
        if let oldBaseURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let oldProjectCacheDirectory = oldBaseURL
                .appendingPathComponent("app_name", isDirectory: true)
                .appendingPathComponent("ProjectCache", isDirectory: true)
            let newProjectCacheDirectory = baseDirectoryURL
                .appendingPathComponent("app_name", isDirectory: true)
                .appendingPathComponent("ProjectCache", isDirectory: true)
            
            if fm.fileExists(atPath: oldProjectCacheDirectory.path) {
                do {
                    try fm.createDirectory(at: newProjectCacheDirectory, withIntermediateDirectories: true)
                    let contents = try fm.contentsOfDirectory(at: oldProjectCacheDirectory, includingPropertiesForKeys: nil)
                    for item in contents {
                        let destination = newProjectCacheDirectory.appendingPathComponent(item.lastPathComponent)
                        if !fm.fileExists(atPath: destination.path) {
                            try fm.moveItem(at: item, to: destination)
                        } else {
                            try fm.removeItem(at: item) // Clean up old duplicate
                        }
                    }
                    try fm.removeItem(at: oldProjectCacheDirectory) // Remove old empty folder
                    print("✅ SubtitleProject: Migrated project caches from Caches to Application Support.")
                } catch {
                    print("⚠️ SubtitleProject: Failed to migrate project caches: \(error.localizedDescription)")
                }
            }
        }
        #else
        guard let baseDirectoryURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        #endif

        return baseDirectoryURL
            .appendingPathComponent("app_name", isDirectory: true)
            .appendingPathComponent("ProjectCache", isDirectory: true)
    }

    nonisolated static func isManagedProjectCacheURL(_ url: URL) -> Bool {
        guard let projectCacheDirectory = projectCacheDirectoryURL else { return false }
        let cachePath = projectCacheDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let urlPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        return urlPath == cachePath || urlPath.hasPrefix(cachePath + "/")
    }

    private func cachedProjectURL(for mediaURL: URL) -> URL? {
        let fm = FileManager.default
        guard let projectCacheDirectory = Self.projectCacheDirectoryURL else {
            return nil
        }

        do {
            try fm.createDirectory(at: projectCacheDirectory, withIntermediateDirectories: true)
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
            projectID: projectIdentifier,
            videoFrameRate: videoFrameRate,
            videoSize: videoSize != .zero ? StropheProjectData.StropheVideoSize(width: videoSize.width, height: videoSize.height) : nil,
            isAudioOnly: isAudioOnly,
            showSoftSubtitles: showSoftSubtitles,
            editingModeRaw: editingMode.rawValue,
            subtitleCollisionModeRaw: subtitleCollisionMode.rawValue,
            currentTime: currentTime,
            createdAt: projectCreatedAt,
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
            version: StropheProjectData.currentVersion,
            metadata: metadata,
            media: media,
            tracks: [defaultTrack],
            styles: [],
            subgroupStyles: StyleAndGroupStore.shared.storedStyles(),
            subtitleGroups: StyleAndGroupStore.shared.storedGroups(),
            interchangeDocuments: subtitleSourceDocuments,
            timeline: ProjectTimelineState(
                markers: markers,
                inPoint: inPoint,
                outPoint: outPoint,
                loopsSelection: loopsSelection
            )
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
        
        try await writeProjectData(encoded, to: url)
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
            let decoded = try decoder.decode(StropheProjectData.self, from: rawData)
            return try StropheProjectMigrator.migrate(decoded)
        }.value

        try await loadStropheData(decoded, from: url)
    }

    func loadStropheData(_ decoded: StropheProjectData, from url: URL?) async throws {
        let decoded = try StropheProjectMigrator.migrate(decoded)
        
        // Reset old project state first, which stops activeEngine, resets videoURL to nil, clears waveformData, etc.
        resetForNewMedia()
        videoURL = nil
        
        items = decoded.items
        subtitleSourceDocuments = decoded.interchangeDocuments ?? []
        lastSubtitleImportDiagnostics = []
        StyleAndGroupStore.shared.restore(styles: decoded.subgroupStyles, groups: decoded.subtitleGroups)
        projectIdentifier = decoded.metadata.projectID ?? UUID()
        projectCreatedAt = decoded.metadata.createdAt
        videoFrameRate = decoded.metadata.videoFrameRate
        if let sz = decoded.metadata.videoSize {
            videoSize = CGSize(width: sz.width, height: sz.height)
        }
        isAudioOnly = decoded.metadata.isAudioOnly
        showSoftSubtitles = decoded.metadata.showSoftSubtitles
        subtitleCollisionMode = decoded.metadata.subtitleCollisionMode
        editingMode = decoded.metadata.editingMode
        let timeline = decoded.timeline ?? ProjectTimelineState()
        markers = timeline.markers
        inPoint = timeline.inPoint
        outPoint = timeline.outPoint
        loopsSelection = timeline.loopsSelection
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
                if mediaAccessStatus.state == .resolving || mediaAccessStatus.state == .none {
                    mediaAccessStatus = MediaAccessStatus(
                        state: .missing,
                        requestedURL: media.originalURL,
                        resolvedURL: nil,
                        usesSecurityScope: false,
                        technicalMessage: "The linked media file could not be resolved."
                    )
                }
            }
        } else {
            videoURL = nil
            mediaAccessStatus = .none
        }
        
        markClean()
    }
    
    func resolveMediaURL(media: StropheProjectData.StropheMedia) -> URL? {
        mediaAccessStatus = MediaAccessStatus(
            state: .resolving,
            requestedURL: media.originalURL,
            resolvedURL: nil,
            usesSecurityScope: false,
            technicalMessage: nil
        )
        if let bookmark = media.bookmark, bookmark.count > 64 {
            if let resolved = resolveSecurityScopedBookmark(bookmark) {
                let didAccess = resolved.startAccessingSecurityScopedResource()
                guard FileManager.default.isReadableFile(atPath: resolved.path) else {
                    if didAccess {
                        resolved.stopAccessingSecurityScopedResource()
                    }
                    mediaAccessStatus = MediaAccessStatus(
                        state: .permissionDenied,
                        requestedURL: media.originalURL,
                        resolvedURL: resolved,
                        usesSecurityScope: false,
                        technicalMessage: "The saved bookmark resolved, but the file is not readable."
                    )
                    return nil
                }
                if didAccess {
                    mediaAccessURL?.stopAccessingSecurityScopedResource()
                    mediaAccessURL = resolved
                }
                mediaAccessStatus = .ready(
                    requestedURL: media.originalURL ?? resolved,
                    resolvedURL: resolved,
                    usesSecurityScope: didAccess
                )
                return resolved
            }
        }
        if let originalURL = media.originalURL {
            let resolved = originalURL.resolvingSymlinksInPath()
            if FileManager.default.fileExists(atPath: resolved.path) {
                guard FileManager.default.isReadableFile(atPath: resolved.path) else {
                    mediaAccessStatus = MediaAccessStatus(
                        state: .permissionDenied,
                        requestedURL: originalURL,
                        resolvedURL: resolved,
                        usesSecurityScope: false,
                        technicalMessage: "The original media path exists but is not readable."
                    )
                    return nil
                }
                mediaAccessStatus = .ready(
                    requestedURL: originalURL,
                    resolvedURL: resolved,
                    usesSecurityScope: false
                )
                return originalURL
            }
            print("⚠️ Original file not found at: \(resolved.path)")
            mediaAccessStatus = MediaAccessStatus(
                state: .missing,
                requestedURL: originalURL,
                resolvedURL: nil,
                usesSecurityScope: false,
                technicalMessage: "The original media path no longer exists."
            )
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
        let didAccess = resolvedURL.startAccessingSecurityScopedResource()
        defer { if didAccess { resolvedURL.stopAccessingSecurityScopedResource() } }
        let bookmark: Data
        do {
            bookmark = try resolvedURL.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            print("⚠️ Failed to create bookmark for: \(resolvedURL.path) — \(error.localizedDescription)")
            return nil
        }
        var isStale = false
        do {
            _ = try URL(resolvingBookmarkData: bookmark, options: bookmarkResolutionOptions, relativeTo: nil, bookmarkDataIsStale: &isStale)
        } catch {
            print("⚠️ Created bookmark is invalid for: \(resolvedURL.path) — \(error.localizedDescription)")
            return nil
        }
        return bookmark
    }
    
    func resolveSecurityScopedBookmark(_ bookmark: Data) -> URL? {
        var isStale = false
        if let resolved = try? URL(resolvingBookmarkData: bookmark, options: bookmarkResolutionOptions, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            if isStale {
                print("⚠️ Bookmark is stale")
            }
            return resolved
        }
        return nil
    }
    
    func createProjectURLBookmark(_ url: URL) -> Data? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            return try url.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            print("⚠️ Failed to create project bookmark for: \(url.path) — \(error.localizedDescription)")
            return nil
        }
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
            try await writeProjectData(encoded, to: resolvedURL ?? url)
            markClean()
        } catch {
            print("⚠️ Auto-save failed: \(error.localizedDescription)")
        }
    }

    private func writeProjectData(_ encoded: Data, to url: URL) async throws {
        let projectID = projectIdentifier
        try await Task.detached(priority: .utility) {
            if let previous = try? Data(contentsOf: url), previous != encoded {
                ProjectBackupStore.archive(
                    previous,
                    projectID: projectID,
                    sourceURL: url
                )
            }
            try encoded.write(to: url, options: .atomic)
        }.value
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
        let totalMs = Int((seconds * 1000).rounded())
        let ms = totalMs % 1000
        let s = (totalMs / 1000) % 60
        let m = (totalMs / (1000 * 60)) % 60
        let h = totalMs / (1000 * 60 * 60)
        
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
