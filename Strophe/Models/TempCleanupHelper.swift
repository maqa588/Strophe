import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class TempCleanupHelper {
    /// Deletes all files and directories inside the application's temporary directory.
    static func cleanupTempDirectory() {
        let tempDir = FileManager.default.temporaryDirectory
        
        // Enumerate directory contents shallowly
        guard let enumerator = FileManager.default.enumerator(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            print("⚠️ TempCleanupHelper: Failed to create enumerator for temp directory.")
            return
        }
        
        print("🧹 TempCleanupHelper: Starting cleanup of temporary directory...")
        
        while let fileURL = enumerator.nextObject() as? URL {
            // "TemporaryItems" is managed by macOS system/sandbox, skip it.
            if fileURL.lastPathComponent == "TemporaryItems" {
                continue
            }
            
            do {
                try FileManager.default.removeItem(at: fileURL)
                print("✅ TempCleanupHelper: Removed \(fileURL.lastPathComponent)")
            } catch {
                print("⚠️ TempCleanupHelper: Failed to remove \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        
        print("🧹 TempCleanupHelper: Cleanup complete.")
    }
    
    /// Registers observer to clean up when the app is about to terminate.
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
            cleanupTempDirectory()
        }
    }
    
    /// Performs cleanup at app startup if temporary directory contains leftover files.
    /// This handles cases where the app crashed or was force-quit without proper cleanup.
    static func performStartupCleanupIfNeeded() {
        let tempDir = FileManager.default.temporaryDirectory
        
        // Check if temp directory has any content (excluding system directories)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return
        }
        
        // Filter out system directories that we should never touch
        let userFiles = contents.filter { url in
            let name = url.lastPathComponent
            return name != "TemporaryItems" && 
                   !name.hasPrefix(".") &&
                   !name.hasPrefix("com.apple")
        }
        
        guard !userFiles.isEmpty else {
            print("🧹 TempCleanupHelper: No leftover temp files detected at startup.")
            return
        }
        
        print("🧹 TempCleanupHelper: Detected \(userFiles.count) leftover item(s) from previous session, cleaning up...")
        cleanupTempDirectory()
    }
    
    /// Computes the total size of files in the temporary directory in bytes.
    static func getTempDirectorySize() -> Int64 {
        let tempDir = FileManager.default.temporaryDirectory
        var size: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: tempDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        
        while let fileURL = enumerator.nextObject() as? URL {
            if fileURL.lastPathComponent == "TemporaryItems" {
                continue
            }
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = resourceValues.fileSize {
                size += Int64(fileSize)
            }
        }
        return size
    }
    
    /// Formats bytes into human-readable string.
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
