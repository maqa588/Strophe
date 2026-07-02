import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

struct WelcomeRecentProject: Codable, Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var lastOpened: Date

    var url: URL {
        URL(fileURLWithPath: path)
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
        projects.removeAll { $0.path == project.path }
        Self.saveStoredProjects(projects)
    }

    static func remember(_ url: URL) {
        guard url.pathExtension.lowercased() == "strophe" else { return }

        #if os(macOS)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        #endif

        var stored = loadStoredProjects()
        let path = url.path
        stored.removeAll { $0.path == path }
        stored.insert(
            WelcomeRecentProject(
                name: url.deletingPathExtension().lastPathComponent,
                path: path,
                lastOpened: Date()
            ),
            at: 0
        )
        saveStoredProjects(Array(stored.prefix(maxProjectCount)))
    }

    private static func loadStoredProjects() -> [WelcomeRecentProject] {
        let decoder = JSONDecoder()
        let stored: [WelcomeRecentProject]
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? decoder.decode([WelcomeRecentProject].self, from: data) {
            stored = decoded
        } else {
            stored = []
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
            guard !merged.contains(where: { $0.path == project.path }) else { continue }
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
