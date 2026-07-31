import Foundation
import Darwin
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

nonisolated final class TempCleanupHelper {
    private static let exportDirectoryName = "StropheExports"
    private static let exportSessionName =
        "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"

    private static var exportRootDirectoryURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(exportDirectoryName, isDirectory: true)
    }

    static var exportSessionDirectoryURL: URL {
        let directory =
            exportRootDirectoryURL
            .appendingPathComponent(exportSessionName, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func isCleanupCandidate(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("strophe_ai_") || name.hasPrefix("strophe_cloud_align_")
            || name.hasPrefix("strophe_media_") || name.hasSuffix(".strophe")
    }

    private static func exportCleanupCandidates(
        removeCurrentSession: Bool
    ) -> [URL] {
        guard
            let items = try? FileManager.default.contentsOfDirectory(
                at: exportRootDirectoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return items.filter { item in
            let name = item.lastPathComponent
            if name == exportSessionName {
                return removeCurrentSession
            }

            guard
                let pidComponent = name.split(
                    separator: "-",
                    maxSplits: 1
                ).first,
                let pid = Int32(pidComponent)
            else {
                // Files created by older Strophe versions are not session
                // scoped, so they are safe to treat as crash leftovers.
                return true
            }
            return !isProcessRunning(pid)
        }
    }

    private static func isProcessRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if pid == getpid() { return true }

        errno = 0
        if kill(pid, 0) == 0 {
            return true
        }
        // A sandbox may deny process inspection even while the process is
        // alive. Preserving its directory is safer than deleting active work.
        return errno == EPERM
    }

    // MARK: - General Temp Directory Cleanup

    /// Removes temporary artifacts known to be owned by Strophe.
    @discardableResult
    static func cleanupTempDirectory(
        removeCurrentExportSession: Bool = false
    ) -> Int {
        let tempDir = FileManager.default.temporaryDirectory
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: tempDir,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
        else {
            print("⚠️ TempCleanupHelper: Failed to read temporary directory.")
            return 0
        }

        print("🧹 TempCleanupHelper: Starting cleanup of temporary directory...")
        var removedCount = 0
        var failedCount = 0
        let candidates =
            contents.filter(isCleanupCandidate)
            + exportCleanupCandidates(
                removeCurrentSession: removeCurrentExportSession
            )
        for fileURL in candidates {
            let name = fileURL.lastPathComponent

            do {
                try FileManager.default.removeItem(at: fileURL)
                removedCount += 1
                print("✅ TempCleanupHelper: Removed \(name)")
            } catch {
                failedCount += 1
                print("⚠️ TempCleanupHelper: Failed to remove \(name): \(error.localizedDescription)")
            }
        }
        print(
            "🧹 TempCleanupHelper: Cleanup complete. Removed \(removedCount) item(s), failed to remove \(failedCount) item(s)."
        )
        return removedCount
    }

    // MARK: - AI Model Temp Cache Cleanup

    /// Removes AI working copies left behind after a crash or forced termination.
    static func cleanupAIModelTempCopies() {
        let tempDir = FileManager.default.temporaryDirectory
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: tempDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsSubdirectoryDescendants]
            )
        else { return }

        let aiTempItems = contents.filter { $0.lastPathComponent.hasPrefix("strophe_ai_") }
        guard !aiTempItems.isEmpty else {
            print("🤖 TempCleanupHelper: No AI model temp copies found.")
            return
        }

        print("🤖 TempCleanupHelper: Cleaning up \(aiTempItems.count) AI model temp item(s)...")
        for item in aiTempItems {
            do {
                try FileManager.default.removeItem(at: item)
                print("   ✓ Removed AI temp: \(item.lastPathComponent)")
            } catch {
                print("   ⚠️ Failed to remove AI temp \(item.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - App Lifecycle Hooks

    /// Registers the process-lifetime termination cleanup hook.
    static func registerForTerminationCleanup() {
        #if os(macOS)
            let notificationName = NSApplication.willTerminateNotification
        #else
            let notificationName = UIApplication.willTerminateNotification
        #endif

        NotificationCenter.default.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { _ in
            print("💾 TempCleanupHelper: App is terminating, performing exit cleanup...")
            cleanupAIModelTempCopies()
            cleanupTempDirectory(
                removeCurrentExportSession: true
            )
        }
    }

    /// Removes artifacts left by earlier process sessions.
    static func performStartupCleanupIfNeeded() {
        let tempDir = FileManager.default.temporaryDirectory
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: tempDir,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
        else { return }

        let userFiles =
            contents.filter(isCleanupCandidate)
            + exportCleanupCandidates(removeCurrentSession: false)

        guard !userFiles.isEmpty else {
            print("🧹 TempCleanupHelper: No leftover temp files detected at startup.")
            return
        }

        print("🧹 TempCleanupHelper: Detected \(userFiles.count) leftover item(s) from previous session, cleaning up...")
        cleanupAIModelTempCopies()
        cleanupTempDirectory()
    }

    // MARK: - Utilities

    /// Returns the total byte size of temporary artifacts owned by Strophe.
    static func tempDirectorySize() -> Int64 {
        let tempDir = FileManager.default.temporaryDirectory
        var size: Int64 = 0
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: tempDir,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
        else { return 0 }

        var roots = contents.filter(isCleanupCandidate)
        if FileManager.default.fileExists(atPath: exportRootDirectoryURL.path) {
            roots.append(exportRootDirectoryURL)
        }

        for root in roots {
            if let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
                rootValues.isDirectory != true
            {
                size += Int64(rootValues.fileSize ?? 0)
                continue
            }

            guard
                let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }

            for case let fileURL as URL in enumerator {
                guard
                    let values = try? fileURL.resourceValues(
                        forKeys: [.isRegularFileKey, .fileSizeKey]
                    ), values.isRegularFile == true
                else { continue }
                size += Int64(values.fileSize ?? 0)
            }
        }
        return size
    }

    /// Formats a byte count using file-size units.
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
