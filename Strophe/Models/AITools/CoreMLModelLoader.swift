#if STROPHE_LOCAL_AI
import CoreML
import Foundation

nonisolated enum CoreMLModelLoader {
    static func load(
        named name: String,
        from directory: URL,
        configuration: MLModelConfiguration
    ) throws -> MLModel {
        let bundledCompiled = directory.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        if FileManager.default.fileExists(atPath: bundledCompiled.path) {
            return try MLModel(contentsOf: bundledCompiled, configuration: configuration)
        }

        let package = directory.appendingPathComponent("\(name).mlpackage", isDirectory: true)
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw CoreMLQwen3Error.model("缺少 \(name).mlmodelc 或 \(name).mlpackage")
        }

        let cacheDirectory = directory.appendingPathComponent(".strophe-compiled", isDirectory: true)
        let cachedModel = cacheDirectory.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        if FileManager.default.fileExists(atPath: cachedModel.path) {
            do {
                return try MLModel(contentsOf: cachedModel, configuration: configuration)
            } catch {
                try? FileManager.default.removeItem(at: cachedModel)
            }
        }

        let compiledTemporary = try MLModel.compileModel(at: package)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let staging = cacheDirectory.appendingPathComponent(".\(name)-\(UUID().uuidString).mlmodelc", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: compiledTemporary, to: staging)
        if FileManager.default.fileExists(atPath: cachedModel.path) {
            try FileManager.default.removeItem(at: cachedModel)
        }
        try FileManager.default.moveItem(at: staging, to: cachedModel)
        return try MLModel(contentsOf: cachedModel, configuration: configuration)
    }
}
#endif
