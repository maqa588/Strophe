//
//  ProjectBackupStore.swift
//  Strophe
//

import Foundation

nonisolated struct ProjectBackupSnapshot: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var projectID: UUID
    var createdAt: Date
    var sourceFileName: String
    var backupURL: URL
    var byteCount: Int
}

/// Rolling, app-owned project snapshots. Snapshots live outside the source
/// document, so replacing or corrupting a `.strophe` file does not erase its
/// recovery history.
nonisolated enum ProjectBackupStore {
    static let maximumSnapshotsPerProject = 50

    static var rootDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Strophe", isDirectory: true)
            .appendingPathComponent("ProjectBackups", isDirectory: true)
    }

    static func clearAll(rootDirectoryOverride: URL? = nil) {
        guard let storageRoot = rootDirectoryOverride ?? rootDirectory else {
            return
        }
        do {
            try FileManager.default.removeItem(at: storageRoot)
        } catch {
            print("⚠️ Clear all snapshots failed: \(error.localizedDescription)")
        }
    }

    static func archive(
        _ data: Data,
        projectID: UUID,
        sourceURL: URL,
        createdAt: Date = Date(),
        rootDirectoryOverride: URL? = nil
    ) {
        guard !data.isEmpty,
              let storageRoot = rootDirectoryOverride ?? rootDirectory else {
            return
        }
        let projectDirectory = storageRoot
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: projectDirectory,
                withIntermediateDirectories: true
            )
            let timestamp = backupTimestamp(createdAt)
            let sourceName = safeFileName(sourceURL.lastPathComponent)
            let fileName = "\(timestamp)--\(UUID().uuidString.prefix(8))--\(sourceName)"
            let destination = projectDirectory.appendingPathComponent(fileName)
            try data.write(to: destination, options: .atomic)
            try prune(projectDirectory)
        } catch {
            // A failed backup must never prevent the primary project save.
            print("⚠️ Project backup failed: \(error.localizedDescription)")
        }
    }

    static func snapshots(
        projectID: UUID? = nil,
        rootDirectoryOverride: URL? = nil
    ) -> [ProjectBackupSnapshot] {
        guard let storageRoot = rootDirectoryOverride ?? rootDirectory else {
            return []
        }
        let fm = FileManager.default
        let directories: [URL]
        if let projectID {
            directories = [
                storageRoot.appendingPathComponent(
                    projectID.uuidString,
                    isDirectory: true
                )
            ]
        } else {
            directories = (try? fm.contentsOfDirectory(
                at: storageRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }

        return directories.flatMap { directory -> [ProjectBackupSnapshot] in
            guard let directoryProjectID = UUID(uuidString: directory.lastPathComponent) else {
                return []
            }
            let files = (try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return files.compactMap { url in
                guard url.pathExtension.lowercased() == "strophe" else { return nil }
                let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                )
                return ProjectBackupSnapshot(
                    id: stableID(for: url),
                    projectID: directoryProjectID,
                    createdAt: values?.contentModificationDate ?? .distantPast,
                    sourceFileName: originalSourceName(from: url),
                    backupURL: url,
                    byteCount: values?.fileSize ?? 0
                )
            }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func load(_ snapshot: ProjectBackupSnapshot) throws -> StropheProjectData {
        let data = try Data(contentsOf: snapshot.backupURL)
        let decoded = try JSONDecoder().decode(StropheProjectData.self, from: data)
        return try StropheProjectMigrator.migrate(decoded)
    }

    private static func prune(_ directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "strophe" }
        .sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lhs > rhs
        }
        guard files.count > maximumSnapshotsPerProject else { return }
        for expired in files.dropFirst(maximumSnapshotsPerProject) {
            try FileManager.default.removeItem(at: expired)
        }
    }

    private static func backupTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    private static func safeFileName(_ value: String) -> String {
        let sanitized = value.map { character -> Character in
            switch character {
            case "/", "\\", ":", "\0":
                return "-"
            default:
                return character
            }
        }
        let result = String(sanitized).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "project.strophe" : result
    }

    private static func originalSourceName(from backupURL: URL) -> String {
        let name = backupURL.lastPathComponent
        let components = name.components(separatedBy: "--")
        guard components.count >= 3 else { return name }
        return components.dropFirst(2).joined(separator: "--")
    }

    private static func stableID(for url: URL) -> UUID {
        // The filename contains a UUID fragment but not a complete UUID. A
        // deterministic hash keeps SwiftUI list identity stable between scans.
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in url.path.utf8.enumerated() {
            bytes[index % 16] = bytes[index % 16] &+ byte &+ UInt8(index & 0xFF)
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
