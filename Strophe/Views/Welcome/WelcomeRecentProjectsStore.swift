import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

#if os(macOS)
private let bookmarkCreationOptions = URL.BookmarkCreationOptions.withSecurityScope
private let bookmarkResolutionOptions = URL.BookmarkResolutionOptions.withSecurityScope
#else
private let bookmarkCreationOptions = URL.BookmarkCreationOptions()
private let bookmarkResolutionOptions = URL.BookmarkResolutionOptions()
#endif

struct WelcomeRecentProject: Codable, Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var lastOpened: Date
    var bookmark: Data?

    var url: URL {
        URL(fileURLWithPath: WelcomeRecentProject.normalizePath(path))
    }

    var isInManagedProjectCache: Bool {
        SubtitleProject.isManagedProjectCacheURL(url)
    }

    /// Resolve the stored security-scoped bookmark and start accessing the resource.
    /// Returns the resolved URL with active sandbox access, or nil if no bookmark or resolution failed.
    func resolveBookmark() -> URL? {
        guard let bookmark = bookmark else { return nil }
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        _ = resolved.startAccessingSecurityScopedResource()
        return resolved
    }

    /// Create a security-scoped bookmark for the given URL.
    static func createBookmark(for url: URL) -> Data? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(
            options: bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func normalizePath(_ path: String) -> String {
        #if os(iOS)
        let fileManager = FileManager.default
        if let range = path.range(of: "/Library/Caches/") {
            let relativePath = String(path[range.upperBound...])
            if let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
                return cachesURL.appendingPathComponent(relativePath).path
            }
        } else if let range = path.range(of: "/Library/Application Support/") {
            let relativePath = String(path[range.upperBound...])
            if let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                return appSupportURL.appendingPathComponent(relativePath).path
            }
        } else if let range = path.range(of: "/Documents/") {
            let relativePath = String(path[range.upperBound...])
            if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                return documentsURL.appendingPathComponent(relativePath).path
            }
        }
        #endif
        return path
    }
}

@MainActor
final class WelcomeRecentProjectsStore: ObservableObject {
    @Published private(set) var projects: [WelcomeRecentProject] = []

    private static let storageKey = "com.strophe.recentProjects"
    private static let maxProjectCount = 12

    init() {
        reload()
    }

    func reload() {
        projects = Self.loadStoredProjects()
    }

    func remember(_ url: URL) {
        Self.remember(url)
        reload()
    }

    func remove(_ project: WelcomeRecentProject) {
        remove(project, deletingCachedFile: false)
    }

    func remove(_ project: WelcomeRecentProject, deletingCachedFile: Bool) {
        Self.remove(project, deletingCachedFile: deletingCachedFile)
        reload()
    }

    static func remove(_ project: WelcomeRecentProject, deletingCachedFile: Bool = false) {
        let normalizedPath = WelcomeRecentProject.normalizePath(project.path)
        var stored = loadStoredProjects()
        stored.removeAll { WelcomeRecentProject.normalizePath($0.path) == normalizedPath }
        saveStoredProjects(stored)

        #if os(macOS)
        NSDocumentController.shared.clearRecentDocuments(nil)
        for recentProject in stored {
            NSDocumentController.shared.noteNewRecentDocumentURL(recentProject.url)
        }
        #endif

        if deletingCachedFile, project.isInManagedProjectCache {
            try? FileManager.default.removeItem(at: project.url)
        }
    }

    static func remove(_ url: URL, deletingCachedFile: Bool = false) {
        let normalizedPath = WelcomeRecentProject.normalizePath(url.path)
        let project = WelcomeRecentProject(
            name: url.deletingPathExtension().lastPathComponent,
            path: normalizedPath,
            lastOpened: Date(),
            bookmark: nil
        )
        remove(project, deletingCachedFile: deletingCachedFile)
    }

    static func remember(_ url: URL) {
        guard url.pathExtension.lowercased() == "strophe" else { return }

        #if os(macOS)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        #endif

        let bookmark = WelcomeRecentProject.createBookmark(for: url)

        var stored = loadStoredProjects()
        let path = WelcomeRecentProject.normalizePath(url.path)
        stored.removeAll { WelcomeRecentProject.normalizePath($0.path) == path }
        stored.insert(
            WelcomeRecentProject(
                name: url.deletingPathExtension().lastPathComponent,
                path: path,
                lastOpened: Date(),
                bookmark: bookmark
            ),
            at: 0
        )
        saveStoredProjects(Array(stored.prefix(maxProjectCount)))
    }

    private static func loadStoredProjects() -> [WelcomeRecentProject] {
        let decoder = JSONDecoder()
        var stored: [WelcomeRecentProject] = []
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? decoder.decode([WelcomeRecentProject].self, from: data) {
            #if os(iOS)
            stored = decoded.map {
                var p = $0
                p.path = WelcomeRecentProject.normalizePath(p.path)
                return p
            }
            #else
            stored = decoded
            #endif
        }

        #if os(macOS)
        let documentControllerProjects = NSDocumentController.shared.recentDocumentURLs
            .filter { $0.pathExtension.lowercased() == "strophe" }
            .map {
                WelcomeRecentProject(
                    name: $0.deletingPathExtension().lastPathComponent,
                    path: $0.path,
                    lastOpened: Date.distantPast
                )
            }
        #else
        let documentControllerProjects: [WelcomeRecentProject] = []
        #endif

        var merged: [WelcomeRecentProject] = []
        for project in stored + documentControllerProjects {
            let normalizedPath = WelcomeRecentProject.normalizePath(project.path)
            guard !merged.contains(where: { WelcomeRecentProject.normalizePath($0.path) == normalizedPath }) else { continue }
            merged.append(project)
        }

        return Array(
            merged
                .sorted { $0.lastOpened > $1.lastOpened }
                .prefix(maxProjectCount)
        )
    }

    private static func saveStoredProjects(_ projects: [WelcomeRecentProject]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
