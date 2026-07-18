//
//  LocalModelManager.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/28.
//

import Foundation
import Combine

enum AIKitType: String, CaseIterable, Codable, Sendable {
    case whisper = "Whisper"
    case aligner = "ForcedAligner"
    case vad = "VADKit"
    case speaker = "SpeakerKit"
    case tts = "TTSKit"
    case other = "Other"

    var title: String {
        switch self {
        case .whisper: return "speech_transcription_settings"
        case .aligner: return "forced_alignment_settings"
        case .vad:     return "voice_activity_detection_settings"
        case .speaker: return "speaker_diarization_settings"
        case .tts:     return "text_to_speech_settings"
        case .other:   return "smart_noise_reduction_auxiliary_settings"
        }
    }
}

struct AIModelInfo: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let size: String
    let description: String
    let folderName: String
}

// MARK: - Model presets

extension LocalModelManager {
    nonisolated static let isPureCoreMLPipeline = true
    nonisolated static let coreMLASRAccelerationModelName = "qwen3-asr-coreml"
    nonisolated static let forcedAlignerINT8ModelName = "qwen3-forced-aligner-0.6b-coreml-int8"

    static let whisperPresets = [
        AIModelInfo(name: coreMLASRAccelerationModelName, size: "约 940MB", description: "Qwen3-ASR 0.6B · 全 CoreML（INT8）", folderName: coreMLASRAccelerationModelName)
    ]

    static let coreMLASRAccelerationPreset = AIModelInfo(
        name: coreMLASRAccelerationModelName,
        size: "约 940MB",
        description: "Qwen3-ASR 0.6B · 全 CoreML（INT8）",
        folderName: coreMLASRAccelerationModelName
    )

    static let alignerPresets = [
        AIModelInfo(name: forcedAlignerINT8ModelName, size: "约 1.0GB", description: "Qwen3 ForcedAligner · CoreML INT8（有限值 causal mask）", folderName: forcedAlignerINT8ModelName)
    ]

    static let vadPresets = [
        AIModelInfo(name: "firered-vad-coreml", size: "约 2.2MB", description: "FireRedVAD · 小红书 Stream-VAD · CoreML (智能语音岛划分)", folderName: "firered-vad-coreml")
    ]
    static let speakerPresets: [AIModelInfo] = []
    static let ttsPresets: [AIModelInfo] = []
    static let otherPresets: [AIModelInfo] = []

    static func presets(for type: AIKitType) -> [AIModelInfo] {
        switch type {
        case .whisper: return whisperPresets
        case .aligner: return alignerPresets
        case .vad:     return vadPresets
        case .speaker: return speakerPresets
        case .tts:     return ttsPresets
        case .other:   return otherPresets
        }
    }

    static func downloadablePresets(for type: AIKitType) -> [AIModelInfo] {
        switch type {
        case .whisper: return whisperPresets
        default: return presets(for: type)
        }
    }

    static func supportsCoreMLASRAcceleration(_ asrModelName: String) -> Bool {
        asrModelName == coreMLASRAccelerationModelName
    }
}

// MARK: - Model IDs (HuggingFace repo IDs)

let modelHFIds: [String: String] = [
    "qwen3-asr-coreml": "aufklarer/Qwen3-ASR-CoreML",
    "qwen3-forced-aligner-0.6b-coreml-int8": "aufklarer/Qwen3-ForcedAligner-0.6B-CoreML-INT8",
    "firered-vad-coreml": "illitan/FireRedVAD-CoreML"
]

private let minimumModelDirectoryBytes: [String: Int64] = [
    "qwen3-asr-coreml": 900_000_000,
    "qwen3-forced-aligner-0.6b-coreml-int8": 700_000_000,
    "firered-vad-coreml": 2_000_000
]

private let expectedModelSizesBytes: [String: Int64] = [
    "qwen3-asr-coreml": 945_000_000,
    "qwen3-forced-aligner-0.6b-coreml-int8": 1_000_000_000,
    "firered-vad-coreml": 2_300_000
]

// MARK: - Manager

@MainActor
final class LocalModelManager: ObservableObject {
    static let shared = LocalModelManager()

    @Published var downloadedWhisperModels: Set<String> = []
    @Published var downloadedAlignerModels: Set<String> = []
    @Published var downloadedVADModels:     Set<String> = []
    @Published var downloadedSpeakerModels: Set<String> = []
    @Published var downloadedTTSModels:     Set<String> = []
    @Published var downloadedOtherModels:   Set<String> = []

    @Published var downloadProgresses: [String: Double] = [:]
    @Published var activeDownloads: Set<String> = []
    @Published var storageAccessError: String?

    private static let bookmarkKey = "AIModels_ExternalStorageBookmark"

    private init() {
        migrateFromCachesToApplicationSupportIfNeeded()
        refreshAll()
    }

    private func migrateFromCachesToApplicationSupportIfNeeded() {
        let fm = FileManager.default
        guard let cachesURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let appSupportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        
        let oldDir = cachesURL.appendingPathComponent("qwen3-speech", isDirectory: true)
        let newDir = appSupportURL.appendingPathComponent("qwen3-speech", isDirectory: true)
        
        guard fm.fileExists(atPath: oldDir.path) else { return }
        
        if !fm.fileExists(atPath: newDir.path) {
            do {
                try fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
                try fm.moveItem(at: oldDir, to: newDir)
                print("✅ LocalModelManager: Migrated models from Caches to Application Support.")
            } catch {
                print("⚠️ LocalModelManager: Failed to move models directory: \(error)")
            }
        } else {
            if let contents = try? fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil) {
                for item in contents {
                    let target = newDir.appendingPathComponent(item.lastPathComponent)
                    do {
                        if fm.fileExists(atPath: target.path) {
                            try fm.removeItem(at: target)
                        }
                        try fm.moveItem(at: item, to: target)
                        print("✅ LocalModelManager: Migrated item \(item.lastPathComponent) to Application Support.")
                    } catch {
                        print("⚠️ LocalModelManager: Failed to migrate item \(item.lastPathComponent): \(error)")
                    }
                }
            }
            try? fm.removeItem(at: oldDir)
        }
    }

    // MARK: - External Storage

    func resolvedExternalURL() -> URL? {
        #if !os(macOS)
        // iOS models must stay inside this app's Application Support directory.
        // Besides making the files reliably available to Core ML, this ensures
        // their on-device size is attributed to this app's "Documents & Data"
        // in Settings. External model storage is a macOS-only feature.
        return nil
        #else
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        do {
            let options: URL.BookmarkResolutionOptions = .withSecurityScope
            let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                print("⚠️ LocalModelManager: Security-scoped bookmark is stale.")
                storageAccessError = "外置存储目录的访问授权已失效，请重新选择该目录。"
            }
            return url
        } catch {
            print("❌ LocalModelManager: Failed to resolve bookmark data: \(error)")
            storageAccessError = "无法恢复外置存储目录权限，请重新选择该目录。"
            return nil
        }
        #endif
    }

    var resolvedExternalDirectory: String {
        resolvedExternalURL()?.path ?? ""
    }

    var storageSummary: String {
        resolvedExternalURL()?.path ?? "Default (Internal)"
    }

    func clearExternalStorageBookmark() {
        try? setExternalStorageURL(nil)
    }

    func saveExternalStorageBookmark(for url: URL) throws {
        try setExternalStorageURL(url)
    }

    private func withExternalAccess<T>(_ block: (URL) -> T) -> T {
        guard let url = resolvedExternalURL() else {
            // Fallback to internal storage root
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return block(appSupport)
        }
        
        let isScoped = url.startAccessingSecurityScopedResource()
        #if os(macOS)
        if !isScoped {
            storageAccessError = "外置存储目录权限已失效，请重新选择该目录。"
        }
        #endif
        defer {
            if isScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return block(url)
    }

    func setExternalStorageURL(_ url: URL?) throws {
        guard let url = url else {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            storageAccessError = nil
            refreshAll()
            return
        }
        
        let isScoped = url.startAccessingSecurityScopedResource()
        #if os(macOS)
        guard isScoped else {
            throw NSError(
                domain: "LocalModelManager.Storage",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "macOS 未授予该目录的写入权限，请在目录选择器中重新选择它。"]
            )
        }
        #endif
        defer {
            if isScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        #if os(macOS)
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        let data = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #endif
        let modelRoot = url.appendingPathComponent("qwen3-speech", isDirectory: true)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        let probe = modelRoot.appendingPathComponent(".strophe-write-test-\(UUID().uuidString)")
        try Data("Strophe".utf8).write(to: probe, options: .atomic)
        try FileManager.default.removeItem(at: probe)
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        storageAccessError = nil
        refreshAll()
    }

    // MARK: - Scanning

    func refreshAll() {
        downloadedWhisperModels = scanLocalModels(for: .whisper)
        downloadedAlignerModels = scanLocalModels(for: .aligner)
        downloadedVADModels     = scanLocalModels(for: .vad)
        downloadedSpeakerModels = []
        downloadedTTSModels     = []
        downloadedOtherModels   = []
    }

    func downloadedSet(for type: AIKitType) -> Set<String> {
        switch type {
        case .whisper: return downloadedWhisperModels
        case .aligner: return downloadedAlignerModels
        case .vad:     return downloadedVADModels
        case .speaker: return downloadedSpeakerModels
        case .tts:     return downloadedTTSModels
        case .other:   return downloadedOtherModels
        }
    }

    func huggingFaceModelId(for modelName: String) -> String? {
        modelHFIds[modelName]
    }

    private func scanLocalModels(for type: AIKitType) -> Set<String> {
        withExternalAccess { _ in
            let base = self.getBaseDirectory(for: type)
            var found = Set<String>()

            for preset in Self.downloadablePresets(for: type) {
                if let dir = self.getModelDirectory(for: preset.name, type: type) {
                    if self.modelLooksComplete(preset.name, in: dir) {
                        found.insert(preset.name)
                        continue
                    }
                }
                let legacy = base.appendingPathComponent(preset.folderName)
                if self.modelLooksComplete(preset.name, in: legacy) {
                    found.insert(preset.name)
                }
            }
            return found
        }
    }

    private func modelLooksComplete(_ modelName: String, in directory: URL) -> Bool {
        guard modelDirectoryHasWeights(directory) else { return false }
        let required: [String]
        switch modelName {
        case Self.coreMLASRAccelerationModelName:
            required = ["config.json", "vocab.json", "merges.txt", "tokenizer_config.json",
                        "encoder.mlmodelc", "embedding.mlmodelc", "decoder_part1.mlmodelc", "decoder_part2.mlmodelc"]
        case Self.forcedAlignerINT8ModelName:
            required = ["config.json", "vocab.json", "merges.txt", "tokenizer_config.json"]
        case "firered-vad-coreml":
            required = []
        default:
            required = []
        }
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) else { return false }
        if modelName == Self.forcedAlignerINT8ModelName {
            let components = ["audio_encoder", "text_decoder"]
            guard components.allSatisfy({ component in
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(component).mlmodelc").path) ||
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(component).mlpackage").path)
            }) else { return false }
            guard FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("embed_tokens.fp16.bin").path
            ) else { return false }
        } else if modelName == "firered-vad-coreml" {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("FireRedVAD.mlmodelc").path) ||
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent("FireRedVAD.mlpackage").path)
            else { return false }
        }
        guard let minimumBytes = minimumModelDirectoryBytes[modelName] else { return true }
        return directorySize(directory) >= minimumBytes
    }

    nonisolated private func modelDirectoryHasWeights(_ directory: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return false }
        // Enumerate without isRegularFileKey so we also see directories like .mlmodelc and .mlpackage
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        let weightExtensions: Set<String> = [
            "safetensors", "bin", "gguf", "npy", "npz", "mlmodelc", "mlpackage"
        ]

        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if weightExtensions.contains(ext) {
                return true
            }
        }
        return false
    }

    nonisolated private func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Directory Resolution

    func getBaseDirectory(for type: AIKitType) -> URL {
        #if os(macOS)
        if let ext = resolvedExternalURL() {
            let dir = ext.appendingPathComponent("qwen3-speech", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        #endif
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("qwen3-speech", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        
        return dir
    }

    func getModelDirectory(for modelName: String, type: AIKitType) -> URL? {
        let base = getBaseDirectory(for: type)
        guard let hfId = modelHFIds[modelName] else {
            if let preset = Self.downloadablePresets(for: type).first(where: { $0.name == modelName }) {
                return base.appendingPathComponent(preset.folderName)
            }
            return base.appendingPathComponent(modelName)
        }
        
        let parts = hfId.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let org = String(parts[0])
        let repo = String(parts[1])
        
        return base
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(org, isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
    }

    // MARK: - Delete / Import / Download Stubs

    func deleteModel(type: AIKitType, modelName: String) {
        var deletionError: Error?
        withExternalAccess { _ in
            if let dir = self.getModelDirectory(for: modelName, type: type) {
                do {
                    if FileManager.default.fileExists(atPath: dir.path) {
                        try FileManager.default.removeItem(at: dir)
                    }
                } catch {
                    deletionError = error
                }
            }
            if let preset = Self.presets(for: type).first(where: { $0.name == modelName }) ??
                Self.alignerPresets.first(where: { $0.name == modelName }) {
                let legacy = self.getBaseDirectory(for: type).appendingPathComponent(preset.folderName)
                if FileManager.default.fileExists(atPath: legacy.path) {
                    do {
                        try FileManager.default.removeItem(at: legacy)
                    } catch {
                        deletionError = deletionError ?? error
                    }
                }
            }
        }
        storageAccessError = deletionError.map { "模型文件删除失败：\($0.localizedDescription)" }
        refreshAll()
    }

    // Download methods are in LocalModelManager+Download.swift
}
