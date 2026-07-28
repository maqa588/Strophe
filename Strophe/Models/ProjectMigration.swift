//
//  ProjectMigration.swift
//  Strophe
//

import Foundation

enum StropheProjectMigrationError: LocalizedError {
    case newerProjectVersion(found: Int, supported: Int)
    case invalidProjectVersion(Int)

    var errorDescription: String? {
        switch self {
        case .newerProjectVersion(let found, let supported):
            return "This project uses version \(found), but this Strophe build supports up to version \(supported)."
        case .invalidProjectVersion(let version):
            return "Invalid Strophe project version: \(version)."
        }
    }
}

/// Central migration pipeline. Every migration is additive and deterministic;
/// loading old data never writes it back until the user explicitly saves.
nonisolated enum StropheProjectMigrator {
    static func migrate(_ source: StropheProjectData) throws -> StropheProjectData {
        guard source.version > 0 else {
            throw StropheProjectMigrationError.invalidProjectVersion(source.version)
        }
        guard source.version <= StropheProjectData.currentVersion else {
            throw StropheProjectMigrationError.newerProjectVersion(
                found: source.version,
                supported: StropheProjectData.currentVersion
            )
        }

        var migrated = source
        if migrated.version == 1 {
            migrated.version = 2
            migrated.interchangeDocuments = migrated.interchangeDocuments ?? []
            migrated.timeline = migrated.timeline ?? ProjectTimelineState()
        }
        return migrated
    }
}
