//
//  LocalModelManager+Download.swift
//  Strophe
//
//  Created by Antigravity on 2026/07/12.
//

import Foundation

// MARK: - Download

extension LocalModelManager {

    func downloadModel(type: AIKitType, modelName: String) async {
        guard AIBackendClient.isLocalDeviceSupported else {
            storageAccessError = AIBackendClient.unsupportedDeviceMessage
            return
        }
        guard let repository = modelHFIds[modelName] else { return }
        let downloadID = "\(type.rawValue)_\(modelName)"
        guard !activeDownloads.contains(downloadID) else { return }
        activeDownloads.insert(downloadID)
        downloadProgresses[downloadID] = 0
        defer {
            activeDownloads.remove(downloadID)
            downloadProgresses.removeValue(forKey: downloadID)
            refreshAll()
        }
        do {
            let externalRoot = resolvedExternalURL()
            let hasExternalAccess = externalRoot?.startAccessingSecurityScopedResource() ?? false
            #if os(macOS)
            if externalRoot != nil && !hasExternalAccess {
                throw NSError(
                    domain: "LocalModelManager.Storage",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "外置存储目录权限已失效。请前往模型设置，重新选择该目录后再下载。"]
                )
            }
            #endif
            defer {
                if hasExternalAccess { externalRoot?.stopAccessingSecurityScopedResource() }
            }
            guard let destination = getModelDirectory(for: modelName, type: type) else { return }
            let filters: [String]
            switch modelName {
            case Self.coreMLASRAccelerationModelName:
                filters = ["config.json", "encoder.mlmodelc/", "embedding.mlmodelc/", "decoder_part1.mlmodelc/", "decoder_part2.mlmodelc/"]
            case Self.forcedAlignerINT8ModelName:
                filters = ["config.json", "vocab.json", "merges.txt", "tokenizer_config.json", "audio_encoder.mlpackage/", "embedding.mlpackage/", "text_decoder.mlpackage/"]
            case "firered-vad-coreml":
                filters = ["FireRedVAD.mlpackage/"]
            default:
                filters = []
            }
            try await downloadRepository(repository, to: destination, filters: filters, progressID: downloadID, progressRange: 0...0.98)
            if modelName == Self.coreMLASRAccelerationModelName {
                try await downloadRepository(
                    "aufklarer/Qwen3-ASR-0.6B-MLX-4bit", to: destination,
                    filters: ["vocab.json", "merges.txt", "tokenizer_config.json"],
                    progressID: downloadID, progressRange: 0.98...1.0
                )
            }
            storageAccessError = nil
            downloadProgresses[downloadID] = 1
        } catch {
            storageAccessError = error.localizedDescription
            print("❌ LocalModelManager: \(modelName) 下载失败：\(error.localizedDescription)")
        }
    }

    struct HuggingFaceTreeEntry: Decodable {
        let path: String
        let size: Int64?
        let type: String?
    }

    func downloadRepository(
        _ repository: String,
        to destination: URL,
        filters: [String],
        progressID: String,
        progressRange: ClosedRange<Double>
    ) async throws {
        let apiURL = URL(string: "https://huggingface.co/api/models/\(repository)/tree/main?recursive=true&expand=true")!
        let apiRequest = URLRequest(url: apiURL)
        let (treeData, response) = try await URLSession.shared.data(for: apiRequest)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let entries = try JSONDecoder().decode([HuggingFaceTreeEntry].self, from: treeData)
            .filter { entry in entry.type != "directory" && filters.contains { $0.hasSuffix("/") ? entry.path.hasPrefix($0) : entry.path == $0 } }
        let total = max(entries.reduce(Int64(0)) { $0 + ($1.size ?? 0) }, 1)
        var completed: Int64 = 0
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in entries {
            let target = destination.appendingPathComponent(entry.path)
            if let existing = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               entry.size == nil || Int64(existing) == entry.size {
                completed += entry.size ?? 0
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encodedPath = entry.path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! }.joined(separator: "/")
            let request = URLRequest(url: URL(string: "https://huggingface.co/\(repository)/resolve/main/\(encodedPath)")!)
            let (temporary, fileResponse) = try await URLSession.shared.download(for: request)
            guard (fileResponse as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try safeMoveOrCopyItem(at: temporary, to: target)
            completed += entry.size ?? 0
            let fraction = Double(completed) / Double(total)
            downloadProgresses[progressID] = progressRange.lowerBound + fraction * (progressRange.upperBound - progressRange.lowerBound)
        }
    }

    func safeMoveOrCopyItem(at src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        do {
            try fm.moveItem(at: src, to: dst)
        } catch {
            // Fallback for cross-volume move (e.g. from sandbox temp to external disk)
            try fm.copyItem(at: src, to: dst)
            try? fm.removeItem(at: src)
        }
    }
}
