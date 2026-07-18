import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

nonisolated final class TempCleanupHelper {

    private static func isCleanupCandidate(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("strophe_ai_") ||
            name == "StropheExports" ||
            name.hasSuffix(".mlmodelc") ||
            name.hasSuffix(".strophe") ||
            (name.count == 36 && name.filter { $0 == "-" }.count == 4)
    }

    // MARK: - General Temp Directory Cleanup

    /// 删除应用临时目录下的所有文件和文件夹。
    @discardableResult
    static func cleanupTempDirectory() -> Int {
        let tempDir = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            print("⚠️ TempCleanupHelper: Failed to read temporary directory.")
            return 0
        }

        print("🧹 TempCleanupHelper: Starting cleanup of temporary directory...")
        var removedCount = 0
        var failedCount = 0
        for fileURL in contents where isCleanupCandidate(fileURL) {
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
        print("🧹 TempCleanupHelper: Cleanup complete. Removed \(removedCount) item(s), failed to remove \(failedCount) item(s).")
        return removedCount
    }

    // MARK: - AI Model Temp Cache Cleanup

    /// 清理所有由 SubtitleGenerator 在 /tmp 中建立的 AI 模型临时副本。
    /// 这些副本以 "strophe_ai_" 为前缀，用于在非 APFS 卷上规避 CoreML mmap 限制。
    /// 正常情况下 defer{} 块会即时清理；此函数处理崩溃或强制退出后的残留。
    static func cleanupAIModelTempCopies() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }

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

    /// 注册在应用即将退出时自动执行清理（一般临时文件 + AI 模型副本）。
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
            cleanupAIModelTempCopies()   // 优先清理 AI 模型副本（可能很大）
            cleanupTempDirectory()       // 再清理其余临时文件
        }
    }

    /// 在应用启动时检测并清理上一次 Session 遗留的临时文件（崩溃/强退场景）。
    static func performStartupCleanupIfNeeded() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else { return }

        let userFiles = contents.filter(isCleanupCandidate)

        guard !userFiles.isEmpty else {
            print("🧹 TempCleanupHelper: No leftover temp files detected at startup.")
            return
        }

        print("🧹 TempCleanupHelper: Detected \(userFiles.count) leftover item(s) from previous session, cleaning up...")
        cleanupAIModelTempCopies()
        cleanupTempDirectory()
    }

    // MARK: - Utilities

    /// 计算临时目录中所有文件的总大小（字节）。
    static func getTempDirectorySize() -> Int64 {
        let tempDir = FileManager.default.temporaryDirectory
        var size: Int64 = 0
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else { return 0 }

        for root in contents where isCleanupCandidate(root) {
            if let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
               rootValues.isDirectory != true {
                size += Int64(rootValues.fileSize ?? 0)
                continue
            }

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                ), values.isRegularFile == true else { continue }
                size += Int64(values.fileSize ?? 0)
            }
        }
        return size
    }

    /// 将字节数格式化为人类可读的字符串。
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
