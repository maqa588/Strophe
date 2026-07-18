#if STROPHE_LOCAL_AI
import CoreML
import Foundation
import Metal

nonisolated enum CoreMLModelLoader {
    /// The Neural Engine in first-generation Apple Silicon can fail synchronously
    /// for the ASR decoder, but it can also remain blocked indefinitely while
    /// creating an execution plan for the INT4 ForcedAligner. A thrown error can
    /// fall back normally; a blocked Core ML initializer cannot be cancelled.
    static var shouldBypassNeuralEngineForQwen3: Bool {
        MTLCreateSystemDefaultDevice()?.name.hasPrefix("Apple M1") == true
    }

    static func load(
        named name: String,
        from directory: URL,
        configuration: MLModelConfiguration
    ) throws -> MLModel {
        let fileManager = FileManager.default
        let bundledCompiled = directory.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        let package = directory.appendingPathComponent("\(name).mlpackage", isDirectory: true)
        let cacheDirectory = directory.appendingPathComponent(".strophe-compiled", isDirectory: true)
        let cachedModel = cacheDirectory.appendingPathComponent("\(name).mlmodelc", isDirectory: true)

        if fileManager.fileExists(atPath: bundledCompiled.path) {
            let model = try MLModel(contentsOf: bundledCompiled, configuration: configuration)
            // The compiled model contains its own weight files. Keeping the
            // source package as well doubles Documents & Data on iOS.
            try? fileManager.removeItem(at: package)
            try? removeCacheDirectoryIfEmpty(cacheDirectory, fileManager: fileManager)
            return model
        }

        // Migrate models compiled by older Strophe versions out of the hidden
        // cache, then remove the now-redundant source package.
        if fileManager.fileExists(atPath: cachedModel.path) {
            do {
                try fileManager.moveItem(at: cachedModel, to: bundledCompiled)
                let model = try MLModel(contentsOf: bundledCompiled, configuration: configuration)
                try? fileManager.removeItem(at: package)
                try? removeCacheDirectoryIfEmpty(cacheDirectory, fileManager: fileManager)
                return model
            } catch {
                try? fileManager.removeItem(at: bundledCompiled)
                try? fileManager.removeItem(at: cachedModel)
            }
        }

        guard fileManager.fileExists(atPath: package.path) else {
            throw CoreMLQwen3Error.model("缺少 \(name).mlmodelc 或 \(name).mlpackage")
        }

        print("🔧 CoreML: 首次编译 \(name).mlpackage...")
        let compiledTemporary = try MLModel.compileModel(at: package)
        defer { try? fileManager.removeItem(at: compiledTemporary) }
        let staging = directory.appendingPathComponent(".\(name)-\(UUID().uuidString).mlmodelc", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: compiledTemporary, to: staging)
        try fileManager.moveItem(at: staging, to: bundledCompiled)
        print("✅ CoreML: \(name).mlpackage 编译完成，正在创建执行计划...")
        let model = try MLModel(contentsOf: bundledCompiled, configuration: configuration)
        try? fileManager.removeItem(at: package)
        try? fileManager.removeItem(at: cacheDirectory)
        return model
    }

    private static func removeCacheDirectoryIfEmpty(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let contents = try fileManager.contentsOfDirectory(atPath: directory.path)
        if contents.isEmpty {
            try fileManager.removeItem(at: directory)
        }
    }
}
#endif
