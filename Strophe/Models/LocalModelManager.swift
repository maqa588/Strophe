//
//  LocalModelManager.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/28.
//

import Foundation
import Combine
import HuggingFace
import ZIPFoundation
#if !STROPHE_LITE
import Qwen3ASR
#endif


enum AIKitType: String, CaseIterable, Codable, Sendable {
    case whisper = "Whisper"
    case aligner = "ForcedAligner"
    case vad = "VADKit"
    case speaker = "SpeakerKit"
    case tts = "TTSKit"
    case other = "Other"

    var title: String {
        switch self {
        case .whisper: return "语音转写设置"
        case .aligner: return "强制对齐设置"
        case .vad:     return "语音活动检测设置"
        case .speaker: return "对话人识别设置"
        case .tts:     return "文本转语音设置"
        case .other:   return "智能降噪与辅助设置"
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
    nonisolated static let coreMLASRAccelerationModelName = "qwen3-asr-coreml-int8"

    static let whisperPresets = [
        AIModelInfo(name: "qwen3-asr-0.6b",      size: "680MB", description: "推荐 (MLX 4-bit；可启用 CoreML 编码器加速)", folderName: "qwen3-asr-0.6b"),
        AIModelInfo(name: "qwen3-asr-1.7b",      size: "2.1GB", description: "高精度 (MLX 4-bit，适合高配 Apple 芯片设备)",           folderName: "qwen3-asr-1.7b"),
        AIModelInfo(name: "parakeet-tdt-0.6b",   size: "1.1GB", description: "极速转写 (高吞吐量快速解码)",    folderName: "parakeet-tdt-0.6b")
    ]

    static let coreMLASRAccelerationPreset = AIModelInfo(
        name: coreMLASRAccelerationModelName,
        size: "180MB",
        description: "CoreML INT8 音频编码器；可与 qwen3-asr-0.6b 组合使用以启用 ANE+GPU 混合加速",
        folderName: coreMLASRAccelerationModelName
    )

    static let alignerPresets = [
        AIModelInfo(name: "qwen3-forced-aligner-0.6b-mlx-4bit", size: "979MB", description: "推荐 (MLX 4-bit，80ms 词级时间戳)", folderName: "qwen3-forced-aligner-0.6b-mlx-4bit"),
        AIModelInfo(name: "qwen3-forced-aligner-0.6b-coreml-int4", size: "662MB", description: "CoreML INT4 (已加入下载；当前推理 SDK 暂未暴露 CoreML 对齐器)", folderName: "qwen3-forced-aligner-0.6b-coreml-int4")
    ]

    static let vadPresets = [
        AIModelInfo(name: "pyannote-segmentation-3.0-mlx", size: "5.7MB", description: "Pyannote-Segmentation-3.0 (MLX，高精度离线 VAD / Speech Islands)", folderName: "pyannote-segmentation-3.0-mlx")
    ]

    static let speakerPresets = [
        AIModelInfo(name: "pyannote-diarization-mlx", size: "50MB", description: "推荐 (高精度说话人识别与声纹分离)", folderName: "pyannote-diarization-mlx")
    ]

    static let ttsPresets = [
        AIModelInfo(name: "qwen3-tts-0.6b", size: "1.2GB", description: "推荐 (高品质，轻量快速，多音色合成)", folderName: "qwen3-tts-0.6b"),
        AIModelInfo(name: "qwen3-tts-1.7b", size: "3.4GB", description: "高音质 (高拟真度，支持语气风格控制)",           folderName: "qwen3-tts-1.7b"),
        AIModelInfo(name: "kokoro-82m",     size: "82MB",  description: "极速轻量 (低延迟快速语音合成)", folderName: "kokoro-82m")
    ]

    static let otherPresets = [
        AIModelInfo(name: "deepfilternet3-coreml", size: "15MB", description: "推荐 (智能降噪与人声增强加速)", folderName: "deepfilternet3-coreml"),
        AIModelInfo(name: "spleeter2-coreml", size: "80MB", description: "推荐 (智能提取人声音轨，完美隔离伴奏与背景音乐)", folderName: "spleeter2-coreml")
    ]

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
        case .whisper: return whisperPresets + [coreMLASRAccelerationPreset]
        default: return presets(for: type)
        }
    }

    static func supportsCoreMLASRAcceleration(_ asrModelName: String) -> Bool {
        asrModelName == "qwen3-asr-0.6b"
    }
}

// MARK: - Model IDs (HuggingFace repo IDs)

private let modelHFIds: [String: String] = [
    "qwen3-asr-coreml-int8":      "aufklarer/Qwen3-ASR-CoreML",
    "qwen3-asr-0.6b":           "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",
    "qwen3-asr-1.7b":           "aufklarer/Qwen3-ASR-1.7B-MLX-4bit",
    "parakeet-tdt-0.6b":        "aufklarer/parakeet-tdt-0.6b-mlx",
    "qwen3-forced-aligner-0.6b-mlx-4bit": "aufklarer/Qwen3-ForcedAligner-0.6B-4bit",
    "qwen3-forced-aligner-0.6b-coreml-int4": "aufklarer/Qwen3-ForcedAligner-0.6B-CoreML-INT4",
    "pyannote-segmentation-3.0-mlx": "aufklarer/Pyannote-Segmentation-MLX",
    "pyannote-diarization-mlx": "aufklarer/pyannote-segmentation-3.0-mlx",
    "qwen3-tts-0.6b":           "aufklarer/Qwen3-TTS-0.6B-CoreML",
    "qwen3-tts-1.7b":           "aufklarer/Qwen3-TTS-1.7B-CoreML",
    "kokoro-82m":               "aufklarer/kokoro-82m-coreml",
    "deepfilternet3-coreml":    "aufklarer/DeepFilterNet3-CoreML",
    "spleeter2-coreml":         "aufklarer/Spleeter2-CoreML",
]

private let minimumModelDirectoryBytes: [String: Int64] = [
    "qwen3-asr-coreml-int8": 120_000_000,
    "qwen3-asr-0.6b": 600_000_000,
    "qwen3-asr-1.7b": 1_800_000_000,
    "qwen3-forced-aligner-0.6b-mlx-4bit": 900_000_000,
    "qwen3-forced-aligner-0.6b-coreml-int4": 500_000_000
]

private let expectedModelSizesBytes: [String: Int64] = [
    "qwen3-asr-coreml-int8": 180_000_000,
    "qwen3-asr-0.6b": 680_000_000,
    "qwen3-asr-1.7b": 2_100_000_000,
    "parakeet-tdt-0.6b": 1_100_000_000,
    "qwen3-forced-aligner-0.6b-mlx-4bit": 979_000_000,
    "qwen3-forced-aligner-0.6b-coreml-int4": 662_000_000,
    "pyannote-segmentation-3.0-mlx": 5_700_000,
    "pyannote-diarization-mlx": 50_000_000,
    "qwen3-tts-0.6b": 1_200_000_000,
    "qwen3-tts-1.7b": 3_400_000_000,
    "kokoro-82m": 82_000_000,
    "deepfilternet3-coreml": 15_000_000,
    "spleeter2-coreml": 80_000_000
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

    // UserDefaults key that stores the security-scoped bookmark data
    // One shared external storage root for all AI models.
    private static let bookmarkKey = "AIModels_ExternalStorageBookmark"

    /// UserDefaults key for a user-supplied Hugging Face access token (needed for gated repos).
    static let hfTokenKey = "AIModels_HuggingFaceToken"

    /// The user-supplied Hugging Face token, if any.
    var huggingFaceToken: String {
        get { UserDefaults.standard.string(forKey: Self.hfTokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.hfTokenKey) }
    }

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

    // MARK: - External Storage Bookmark

    /// Returns the resolved **bookmark** URL (the security scope anchor).
    /// Callers must call `startAccessingSecurityScopedResource()` on this URL,
    /// NOT on any derived subdirectory.
    func resolvedExternalURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        #if os(macOS)
        guard let url = try? URL(resolvingBookmarkData: data,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) else { return nil }
        #else
        guard let url = try? URL(resolvingBookmarkData: data,
                                  bookmarkDataIsStale: &isStale) else { return nil }
        #endif
        if isStale {
            print("⚠️ LocalModelManager: External storage bookmark is stale, clearing.")
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            return nil
        }
        return url
    }

    /// Runs `block` inside a properly-scoped security access session for the external volume.
    /// If no external bookmark is configured, `externalURL` passed to block is `nil`.
    @discardableResult
    func withExternalAccess<T>(_ block: (URL?) throws -> T) rethrows -> T {
        guard let scopedURL = resolvedExternalURL() else {
            return try block(nil)
        }
        let didStart = scopedURL.startAccessingSecurityScopedResource()
        defer { if didStart { scopedURL.stopAccessingSecurityScopedResource() } }
        return try block(scopedURL)
    }

    /// Save a security-scoped bookmark for the chosen external directory.
    func saveExternalStorageBookmark(for url: URL) throws {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let data = try url.bookmarkData(options: .withSecurityScope,
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        #else
        let data = try url.bookmarkData(options: [],
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        #endif
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        print("✅ LocalModelManager: Saved external storage bookmark → \(url.path)")
        refreshAll()
    }

    /// Clear the external storage bookmark (revert to sandboxed Caches).
    func clearExternalStorageBookmark() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        print("🗑️ LocalModelManager: External storage bookmark cleared.")
        refreshAll()
    }

    /// A user-displayable string of the current storage root.
    var storageSummary: String {
        if let ext = resolvedExternalURL() { return ext.path }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("qwen3-speech").path
    }

    // MARK: - Directory Resolution

    /// Returns the *base* directory (`qwen3-speech` root) for the given type.
    /// This is the model storage root used by the local AI backend.
    /// Actual model weights live under `<base>/models/<org>/<repo>/`.
    func getBaseDirectory(for type: AIKitType) -> URL {
        if let ext = resolvedExternalURL() {
            let dir = ext.appendingPathComponent("qwen3-speech", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        // Default: sandboxed ~/Library/Application Support/qwen3-speech
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("qwen3-speech", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        // Exclude from iCloud Backup to save user storage quota and conform to Apple rules
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        
        return dir
    }

    /// Returns the exact directory that `fromPretrained(cacheDir:)` expects for a given model.
    /// i.e. `<base>/models/<org>/<repo>` or the legacy flat path.
    func getModelDirectory(for modelName: String, type: AIKitType) -> URL? {
        let base = getBaseDirectory(for: type)
        guard let hfId = modelHFIds[modelName] else { return nil }
        // Hub-style: base/models/org/repo
        let parts = hfId.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return base
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(String(parts[0]), isDirectory: true)
            .appendingPathComponent(String(parts[1]), isDirectory: true)
    }

    // MARK: - Scanning

    func refreshAll() {
        downloadedWhisperModels = scanLocalModels(for: .whisper)
        downloadedAlignerModels = scanLocalModels(for: .aligner)
        downloadedVADModels     = scanLocalModels(for: .vad)
        downloadedSpeakerModels = scanLocalModels(for: .speaker)
        downloadedTTSModels     = scanLocalModels(for: .tts)
        downloadedOtherModels   = scanLocalModels(for: .other)
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
        // Security scope MUST be started on the bookmark URL, not derived subdirs.
        withExternalAccess { _ in
            let base = self.getBaseDirectory(for: type)
            var found = Set<String>()

            for preset in Self.downloadablePresets(for: type) {
                // Check Hub-style path: base/models/org/repo
                if let dir = self.getModelDirectory(for: preset.name, type: type) {
                    if self.modelLooksComplete(preset.name, in: dir) {
                        found.insert(preset.name)
                        continue
                    }
                }
                // Check legacy flat path: base/folderName
                let legacy = base.appendingPathComponent(preset.folderName)
                if self.modelLooksComplete(preset.name, in: legacy) {
                    found.insert(preset.name)
                }
            }
            return found
        }
    }

    private func modelLooksComplete(_ modelName: String, in directory: URL) -> Bool {
        if modelName == "spleeter2-coreml" {
            let modelPath1 = directory.appendingPathComponent("Spleeter2Model.mlmodelc")
            let modelPath2 = directory.appendingPathComponent("Spleeter2.mlmodelc")
            return FileManager.default.fileExists(atPath: modelPath1.path) || FileManager.default.fileExists(atPath: modelPath2.path)
        }
        guard modelDirectoryHasWeights(directory) else { return false }
        guard let minimumBytes = minimumModelDirectoryBytes[modelName] else { return true }
        return directorySize(directory) >= minimumBytes
    }

    nonisolated private func modelDirectoryHasWeights(_ directory: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return false }
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        let weightExtensions: Set<String> = [
            "safetensors", "bin", "gguf", "npy", "npz", "mlmodelc", "mlpackage"
        ]
        let requiredMetadata: Set<String> = [
            "config.json", "tokenizer.json", "tokenizer_config.json", "vocab.json", "merges.txt"
        ]
        var foundWeight = false
        var foundMetadata = false

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if requiredMetadata.contains(name) {
                foundMetadata = true
            }
            if weightExtensions.contains(url.pathExtension.lowercased()) || name.hasSuffix(".mlmodelc") {
                foundWeight = true
            }
            if foundWeight && foundMetadata {
                return true
            }
        }

        return foundWeight
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

    // MARK: - Delete / Import

    func deleteModel(type: AIKitType, modelName: String) {
        withExternalAccess { _ in
            let base = self.getBaseDirectory(for: type)
            // Hub-style directory
            if let dir = self.getModelDirectory(for: modelName, type: type) {
                try? FileManager.default.removeItem(at: dir)
            }
            // Legacy flat directory
            if let preset = Self.downloadablePresets(for: type).first(where: { $0.name == modelName }) {
                let legacy = base.appendingPathComponent(preset.folderName)
                if FileManager.default.fileExists(atPath: legacy.path) {
                    try? FileManager.default.removeItem(at: legacy)
                }
            }
        }
        refreshAll()
    }

    func importModel(type: AIKitType, from sourceURL: URL) throws {
        let isSrc = sourceURL.startAccessingSecurityScopedResource()
        defer { if isSrc { sourceURL.stopAccessingSecurityScopedResource() } }

        let base = getBaseDirectory(for: type)
        let isDst = base.startAccessingSecurityScopedResource()
        defer { if isDst { base.stopAccessingSecurityScopedResource() } }

        let folderName = sourceURL.lastPathComponent
        let target = base.appendingPathComponent(folderName)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: sourceURL, to: target)
        refreshAll()
    }

    // MARK: - Download

    func downloadModel(type: AIKitType, modelName: String) async {
        guard Self.downloadablePresets(for: type).contains(where: { $0.name == modelName }) else { return }

        let modelId = "\(type.rawValue)_\(modelName)"
        guard !activeDownloads.contains(modelId) else { return }

        if modelName == "spleeter2-coreml" {
            guard let targetModelDir = getModelDirectory(for: modelName, type: type) else {
                print("❌ LocalModelManager: Failed to get target model directory for \(modelName)")
                return
            }

            activeDownloads.insert(modelId)
            downloadProgresses[modelId] = 0.0

            let bookmarkData = UserDefaults.standard.data(forKey: Self.bookmarkKey)
            let progressCallback: @Sendable (Double, String) -> Void = { [weak self] progress, _ in
                Task { @MainActor [weak self] in
                    self?.downloadProgresses[modelId] = progress
                }
            }

            let zipURL = URL(string: "https://github.com/jiyimeta/swift-spleeter/releases/download/0.2.0/Spleeter2Model.mlmodelc.zip")!
            
            let _ = await Task.detached(priority: .userInitiated) { [targetModelDir, zipURL] in
                var externalURL: URL? = nil
                var isScoped = false
                if let data = bookmarkData {
                    var isStale = false
                    #if os(macOS)
                    if let url = try? URL(resolvingBookmarkData: data,
                                           options: .withSecurityScope,
                                           relativeTo: nil,
                                           bookmarkDataIsStale: &isStale) {
                        externalURL = url
                        isScoped = url.startAccessingSecurityScopedResource()
                        if !isScoped {
                            print("⚠️ LocalModelManager: startAccessingSecurityScopedResource returned false for \(url.path)")
                        }
                    }
                    #else
                    if let url = try? URL(resolvingBookmarkData: data,
                                           bookmarkDataIsStale: &isStale) {
                        externalURL = url
                        isScoped = url.startAccessingSecurityScopedResource()
                    }
                    #endif
                }
                defer { if isScoped { externalURL?.stopAccessingSecurityScopedResource() } }

                do {
                    print("💾 LocalModelManager: Downloading Spleeter from github release → \(targetModelDir.path)")
                    progressCallback(0.01, "Downloading Spleeter zip...")
                    
                    let tempZipURL = try await Self.downloadFile(from: zipURL) { progress in
                        progressCallback(progress, "Downloading Spleeter model...")
                    }
                    
                    progressCallback(0.95, "Extracting Spleeter model...")
                    try FileManager.default.createDirectory(at: targetModelDir, withIntermediateDirectories: true)
                    
                    // Unzip the downloaded file
                    try Self.unzip(fileURL: tempZipURL, to: targetModelDir)
                    
                    // Clean up temp zip
                    try? FileManager.default.removeItem(at: tempZipURL)
                    
                    print("✅ LocalModelManager: Finished downloading and extracting Spleeter")
                    progressCallback(1.0, "Spleeter download complete")
                } catch {
                    print("❌ LocalModelManager: Spleeter download failed: \(error.localizedDescription)")
                }
            }.value

            activeDownloads.remove(modelId)
            downloadProgresses.removeValue(forKey: modelId)
            refreshAll()
            return
        }

        // Resolve on @MainActor
        guard let hfId = modelHFIds[modelName] else {
            print("❌ LocalModelManager: No HF repo ID found for \(modelName)")
            return
        }

        guard let targetModelDir = getModelDirectory(for: modelName, type: type) else {
            print("❌ LocalModelManager: Failed to get target model directory for \(modelName)")
            return
        }

        activeDownloads.insert(modelId)
        downloadProgresses[modelId] = 0.0

        // Capture snapshot of everything we need before leaving MainActor.
        let bookmarkData = UserDefaults.standard.data(forKey: Self.bookmarkKey)
        let hfToken = huggingFaceToken  // may be empty string

        // Resolve cache directory
        let externalURL = resolvedExternalURL()
        let basePath = externalURL?.appendingPathComponent("qwen3-speech", isDirectory: true)
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let cacheDir = basePath ?? appSupportURL.appendingPathComponent("qwen3-speech", isDirectory: true)

        // Start a background progress observer task that periodically scans the directories to update progress
        let progressObserverTask = Task { [weak self] in
            guard let self = self else { return }
            let expectedSize = expectedModelSizesBytes[modelName] ?? 1_000_000_000
            
            while true {
                // Check if the download is still active
                let isActive = await MainActor.run {
                    self.activeDownloads.contains(modelId)
                }
                guard isActive else { break }
                
                // Calculate current size of cache and target directory in a background task
                let currentBytes = await Task.detached(priority: .background) { [weak self, cacheDir, targetModelDir, hfId, externalURL] in
                    guard let self = self else { return Int64(0) }
                    
                    let didStart = externalURL?.startAccessingSecurityScopedResource() ?? false
                    defer { if didStart { externalURL?.stopAccessingSecurityScopedResource() } }
                    
                    var currentSize: Int64 = 0
                    if modelName == "pyannote-diarization-mlx" {
                        let hfId1 = hfId
                        let hfId2 = "aufklarer/WeSpeaker-ResNet34-LM-MLX"
                        
                        let cacheKey1 = "models--" + hfId1.replacingOccurrences(of: "/", with: "--")
                        let cacheKey2 = "models--" + hfId2.replacingOccurrences(of: "/", with: "--")
                        
                        let targetDir1 = targetModelDir
                        let targetDir2 = cacheDir
                            .appendingPathComponent("models", isDirectory: true)
                            .appendingPathComponent("aufklarer", isDirectory: true)
                            .appendingPathComponent("WeSpeaker-ResNet34-LM-MLX", isDirectory: true)
                            
                        currentSize += self.directorySize(cacheDir.appendingPathComponent(cacheKey1))
                        currentSize += self.directorySize(cacheDir.appendingPathComponent(cacheKey2))
                        currentSize += self.directorySize(targetDir1)
                        currentSize += self.directorySize(targetDir2)
                    } else {
                        let cacheKey = "models--" + hfId.replacingOccurrences(of: "/", with: "--")
                        currentSize += self.directorySize(cacheDir.appendingPathComponent(cacheKey))
                        currentSize += self.directorySize(targetModelDir)
                    }
                    return currentSize
                }.value
                
                let progress = Double(currentBytes) / Double(expectedSize)
                let clampedProgress = min(max(progress, 0.01), 0.99)
                
                await MainActor.run {
                    self.downloadProgresses[modelId] = clampedProgress
                }
                
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
        }

        // Progress forwarding closure — called from background, dispatched to MainActor.
        let progressCallback: @Sendable (Double, String) -> Void = { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                // Only overwrite if it is non-trivial, let the directory scanner do the granular work
                if progress > (self?.downloadProgresses[modelId] ?? 0.0) {
                    self?.downloadProgresses[modelId] = progress
                }
            }
        }

        let _ = await Task.detached(priority: .userInitiated) { [modelName, hfId, targetModelDir] in
            // ─── Resolve & start security-scoped access on the BOOKMARK URL ───
            // IMPORTANT: startAccessingSecurityScopedResource must be called on the
            // bookmark-resolved URL, never on a derived subdirectory path.
            var externalURL: URL? = nil
            var isScoped = false
            if let data = bookmarkData {
                var isStale = false
                #if os(macOS)
                if let url = try? URL(resolvingBookmarkData: data,
                                       options: .withSecurityScope,
                                       relativeTo: nil,
                                       bookmarkDataIsStale: &isStale) {
                    externalURL = url
                    isScoped = url.startAccessingSecurityScopedResource()
                    if !isScoped {
                        print("⚠️ LocalModelManager: startAccessingSecurityScopedResource returned false for \(url.path)")
                    }
                }
                #else
                if let url = try? URL(resolvingBookmarkData: data,
                                       bookmarkDataIsStale: &isStale) {
                    externalURL = url
                    isScoped = url.startAccessingSecurityScopedResource()
                }
                #endif
            }
            defer { if isScoped { externalURL?.stopAccessingSecurityScopedResource() } }

            // ─── Determine cacheDir ──────────────────────────────────────────
            let basePath: URL?
            if let ext = externalURL {
                basePath = ext.appendingPathComponent("qwen3-speech", isDirectory: true)
                try? FileManager.default.createDirectory(at: basePath!, withIntermediateDirectories: true)
            } else {
                basePath = nil
            }

            let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let cacheDir = basePath ?? appSupportURL.appendingPathComponent("qwen3-speech", isDirectory: true)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

            // ─── Retry wrapper ────────────────────────────────────────────
            func retry<R>(_ block: () async throws -> R, maxTries: Int = 5) async throws -> R {
                var last: Error?
                for attempt in 1...maxTries {
                    do { return try await block() } catch {
                        last = error
                        print("⚠️ LocalModelManager: attempt \(attempt) failed: \(String(describing: error)). Retrying in 5s…")
                        if attempt < maxTries {
                            try? await Task.sleep(nanoseconds: UInt64(attempt * 5) * 1_000_000_000)
                        }
                    }
                }
                throw last!
            }

            func removePartialDownloadArtifacts(for repoId: String, destination: URL) {
                let fm = FileManager.default
                let keepNames: Set<String> = ["config.json", "tokenizer_config.json", "vocab.json", "merges.txt", "quantize_config.json"]
                if let contents = try? fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) {
                    for file in contents where !keepNames.contains(file.lastPathComponent) {
                        try? fm.removeItem(at: file)
                    }
                }

                let cacheKey = "models--" + repoId.replacingOccurrences(of: "/", with: "--")
                try? fm.removeItem(at: cacheDir.appendingPathComponent(cacheKey))
                try? fm.removeItem(at: cacheDir.appendingPathComponent(".locks").appendingPathComponent(cacheKey))
            }

            let globs = [
                "*.safetensors",
                "*.json",
                "*.txt",
                "*.model",
                "*.npy",
                "*.npz",
                "*mlmodelc/*",
                "*mlpackage/*"
            ]

            // ─── Smart Auth Downloader ─────────────────────────────────────
            // Priority: user-supplied token > HF CLI environment token > anonymous.
            // If a user token is provided, we use it directly (covers gated repos).
            // If no token and we get 401, we report a clear error asking for a token.
            func downloadSnapshotWithAuthFallback(
                of repoId: String,
                to destination: URL,
                progressWeightRange: ClosedRange<Double>,
                progressLabel: String,
                matching patterns: [String] = globs
            ) async throws {
                let cache = HubCache(cacheDirectory: cacheDir)

                // Build token provider: user token takes priority.
                let tokenProvider: TokenProvider
                let trimmedToken = hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedToken.isEmpty {
                    tokenProvider = .fixed(token: trimmedToken)
                    print("🔑 LocalModelManager: Using user-supplied HF token for \(repoId)")
                } else {
                    tokenProvider = .environment  // picks up ~/.cache/huggingface/token if present
                }

                let client = HubClient(
                    host: HubClient.defaultHost,
                    tokenProvider: tokenProvider,
                    cache: cache
                )

                func downloadSnapshot() async throws {
                    _ = try await client.downloadSnapshot(
                        of: Repo.ID(rawValue: repoId)!,
                        kind: .model,
                        to: destination,
                        matching: patterns,
                        maxConcurrentDownloads: 1,
                        progressHandler: { progress in
                            let fraction = progress.fractionCompleted
                            let overall = progressWeightRange.lowerBound + fraction * (progressWeightRange.upperBound - progressWeightRange.lowerBound)
                            progressCallback(max(overall, 0.01), progressLabel)  // ensure at least 1% so UI shows activity
                        }
                    )
                }

                do {
                    do {
                        print("💾 LocalModelManager: Downloading \(repoId) → \(destination.path)")
                        _ = try await retry({
                            try await downloadSnapshot()
                        }, maxTries: 6)
                    } catch {
                        removePartialDownloadArtifacts(for: repoId, destination: destination)
                        print("🧹 LocalModelManager: Cleaned partial download for \(repoId), retrying once from scratch...")
                        _ = try await retry({
                            try await downloadSnapshot()
                        }, maxTries: 3)
                    }
                } catch {
                    let errStr = String(describing: error)
                    if errStr.contains("401") || errStr.contains("403") {
                        // Gated repo — provide a clear, actionable error message.
                        let msg = """
                        当前下载的辅助功能属于受限资源，需要提供 Hugging Face 访问令牌。
                        请在设置中填写您的访问令牌，然后重试下载。
                        (可前往 huggingface.co/settings/tokens 获取)
                        """
                        throw NSError(
                            domain: "LocalModelManager",
                            code: 401,
                            userInfo: [NSLocalizedDescriptionKey: msg]
                        )
                    } else {
                        throw error
                    }
                }
            }

            // ─── Download ─────────────────────────────────────────────────
            do {
                try FileManager.default.createDirectory(at: targetModelDir, withIntermediateDirectories: true)

                if modelName == "pyannote-diarization-mlx" {
                    // For pyannote diarization, we need both:
                    // 1. aufklarer/pyannote-segmentation-3.0-mlx (segmentation model)
                    // 2. aufklarer/WeSpeaker-ResNet34-LM-MLX (speaker embedding model)
                    let embeddingHfId = "aufklarer/WeSpeaker-ResNet34-LM-MLX"

                    let embeddingTargetDir = cacheDir
                        .appendingPathComponent("models", isDirectory: true)
                        .appendingPathComponent("aufklarer", isDirectory: true)
                        .appendingPathComponent("WeSpeaker-ResNet34-LM-MLX", isDirectory: true)
                    try FileManager.default.createDirectory(at: embeddingTargetDir, withIntermediateDirectories: true)

                    print("👥 LocalModelManager: Downloading segmentation model: \(hfId) -> \(targetModelDir.path)")
                    try await downloadSnapshotWithAuthFallback(
                        of: hfId,
                        to: targetModelDir,
                        progressWeightRange: 0.0...0.5,
                        progressLabel: "Downloading segmentation model..."
                    )

                    print("👥 LocalModelManager: Downloading speaker embedding model: \(embeddingHfId) -> \(embeddingTargetDir.path)")
                    try await downloadSnapshotWithAuthFallback(
                        of: embeddingHfId,
                        to: embeddingTargetDir,
                        progressWeightRange: 0.5...1.0,
                        progressLabel: "Downloading speaker embedding model..."
                    )
                } else if modelName == Self.coreMLASRAccelerationModelName {
                    #if STROPHE_LITE
                    print("💾 LocalModelManager: Downloading model snapshot: \(hfId) -> \(targetModelDir.path)")
                    try await downloadSnapshotWithAuthFallback(
                        of: hfId,
                        to: targetModelDir,
                        progressWeightRange: 0.0...1.0,
                        progressLabel: "Downloading model..."
                    )
                    #else
                    func downloadCoreMLEncoder() async throws {
                        _ = try await CoreMLASREncoder.fromPretrained(
                            modelId: hfId,
                            cacheDir: targetModelDir,
                            offlineMode: false
                        ) { fraction, label in
                            progressCallback(max(fraction, 0.01), label)
                        }
                    }

                    print("💾 LocalModelManager: Downloading CoreML ASR encoder: \(hfId) -> \(targetModelDir.path)")
                    do {
                        _ = try await retry({
                            try await downloadCoreMLEncoder()
                        }, maxTries: 3)
                    } catch {
                        removePartialDownloadArtifacts(for: hfId, destination: targetModelDir)
                        print("🧹 LocalModelManager: Cleaned partial CoreML download for \(hfId), retrying once from scratch...")
                        _ = try await retry({
                            try await downloadCoreMLEncoder()
                        }, maxTries: 2)
                    }
                    #endif
                } else {
                    print("💾 LocalModelManager: Downloading model snapshot: \(hfId) -> \(targetModelDir.path)")
                    try await downloadSnapshotWithAuthFallback(
                        of: hfId,
                        to: targetModelDir,
                        progressWeightRange: 0.0...1.0,
                        progressLabel: "Downloading model..."
                    )
                }
                print("✅ LocalModelManager: Finished downloading \(modelName)")
            } catch {
                print("❌ LocalModelManager: Download finally failed for \(modelName): \(String(describing: error))")
            }
        }.value

        progressObserverTask.cancel()

        activeDownloads.remove(modelId)
        downloadProgresses[modelId] = 0.0
        refreshAll()
    }

    nonisolated private static func downloadFile(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadProgressDelegate(
                progressCallback: progress,
                completionCallback: { location, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let location = location {
                        let tempDest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
                        do {
                            try FileManager.default.copyItem(at: location, to: tempDest)
                            continuation.resume(returning: tempDest)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            )
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: OperationQueue())
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    nonisolated private static func unzip(fileURL: URL, to destinationURL: URL) throws {
        try FileManager.default.unzipItem(at: fileURL, to: destinationURL)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progressCallback: @Sendable (Double) -> Void
    let completionCallback: @Sendable (URL?, Error?) -> Void
    private let lock = NSLock()
    private var hasCompleted = false

    init(progressCallback: @escaping @Sendable (Double) -> Void, completionCallback: @escaping @Sendable (URL?, Error?) -> Void) {
        self.progressCallback = progressCallback
        self.completionCallback = completionCallback
        super.init()
    }

    private func complete(with url: URL?, error: Error?, session: URLSession) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasCompleted else { return }
        hasCompleted = true
        completionCallback(url, error)
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressCallback(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        complete(with: location, error: nil, session: session)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            complete(with: nil, error: error, session: session)
        } else {
            lock.lock()
            let completed = hasCompleted
            lock.unlock()
            if !completed {
                complete(with: nil, error: NSError(domain: "DownloadError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download finished but file was not found."]), session: session)
            }
        }
    }
}
