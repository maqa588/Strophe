#if STROPHE_LOCAL_AI
import CoreML
import Foundation

nonisolated enum CoreMLModelLoader {
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

        let compiledTemporary = try MLModel.compileModel(at: package)
        let staging = directory.appendingPathComponent(".\(name)-\(UUID().uuidString).mlmodelc", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: compiledTemporary, to: staging)
        try fileManager.moveItem(at: staging, to: bundledCompiled)
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
