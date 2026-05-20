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
}
