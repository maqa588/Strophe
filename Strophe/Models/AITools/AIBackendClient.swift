//
//  AIBackendClient.swift
//  Strophe
//
//  Created by Codex on 2026/06/04.
//

import Foundation

struct AIGenerateSubtitlesRequest: Sendable {
    let audioURL: URL
    let asrModelName: String
    let whisperModelURL: URL
    let asrDecoderModelURL: URL?
    let alignerModelURL: URL
    let vadModelURL: URL
    let speakerModelURL: URL
    let whisperBaseDir: URL
    let alignerBaseDir: URL
    let speakerBaseDir: URL
    let alignerModelId: String
    let modelStorageRoot: URL?
    let expectedSpeakers: Int?
    let language: String
    let enableDiarization: Bool
    let prefixSpeakerName: Bool
    let enableAlignment: Bool
    let vocalPreprocessing: String
    let referenceText: String?
    let useVAD: Bool
}

enum AICloudASRModel: String, CaseIterable, Identifiable, Sendable {
    case qwen3ASR17B = "qwen3-asr-1.7b"
    case parakeetJA = "parakeet-tdt-ctc-0.6b-ja"

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .qwen3ASR17B: return "Qwen3-ASR 1.7B"
        case .parakeetJA: return "Parakeet-JA 0.6B"
        }
    }

    nonisolated var descriptionKey: String {
        switch self {
        case .qwen3ASR17B: return "cloud_model_description_qwen3"
        case .parakeetJA: return "cloud_model_description_parakeet"
        }
    }

    nonisolated static func recommended(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AICloudASRModel {
        preferredLanguages.first?.lowercased().hasPrefix("ja") == true
            ? .parakeetJA
            : .qwen3ASR17B
    }
}

struct AICloudGenerateSubtitlesRequest: Sendable {
    let mediaURL: URL
    let endpointURL: URL
    let language: String
    let model: AICloudASRModel
    let enableKaraoke: Bool
}

struct AICloudTranscriptionResult: Sendable {
    let language: String?
    let model: String?
    let segments: [AIResultSegment]
}

struct AICloudAlignmentCue: Codable, Sendable {
    let id: UUID
    let text: String
    let startTime: Double
    let endTime: Double
}

struct AICloudAlignmentResult: Sendable {
    let wordsByCueID: [UUID: [SubtitleWordTiming]]
}

struct AICloudConnectionCheck: Sendable {
    let isReady: Bool
    let message: String
}

enum AIBackendAvailability: Sendable {
    case available
    case unavailable(String)
}

actor AIBackendClient {
    static let shared = AIBackendClient()
    nonisolated static let cloudBaseURLDefaultsKey = "cloudRecognitionBaseURL"
    nonisolated static let defaultCloudBaseURL = URL(string: "http://192.168.10.97:8000")!
    nonisolated static var defaultCloudTranscribeURL: URL {
        defaultCloudBaseURL.appendingPathComponent("transcribe")
    }

    nonisolated static func normalizedCloudBaseURL(from input: String) throws -> URL {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw NSError(
                domain: "AIBackendClient.CloudConfiguration",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: localizedAIText(
                        "error_cloud_address_required"
                    )
                ]
            )
        }

        if !value.contains("://") {
            value = "http://\(value)"
        }

        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw NSError(
                domain: "AIBackendClient.CloudConfiguration",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: localizedAIText(
                        "error_cloud_address_invalid"
                    )
                ]
            )
        }

        components.scheme = scheme
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        if components.path == "/" {
            components.path = ""
        }

        guard let url = components.url else {
            throw NSError(
                domain: "AIBackendClient.CloudConfiguration",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: localizedAIText(
                        "error_cloud_address_parse_failed"
                    )
                ]
            )
        }
        return url
    }

    nonisolated static func cloudEndpointURL(baseURL: URL, path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    nonisolated static func cloudTranscribeURL(baseURL: URL) -> URL {
        cloudEndpointURL(baseURL: baseURL, path: "transcribe")
    }

    nonisolated static func cloudAlignURL(baseURL: URL) -> URL {
        cloudEndpointURL(baseURL: baseURL, path: "align")
    }
    #if STROPHE_LOCAL_AI
    nonisolated static let isLocalAIIncludedInBuild = true
    #else
    nonisolated static let isLocalAIIncludedInBuild = false
    #endif
    nonisolated static var unsupportedDeviceMessage: String {
        localizedAIText("error_on_device_ai_unsupported")
    }
    // The complete ASR + ForcedAligner pipeline is only enabled on devices
    // reporting at least 5.5 GiB of physical memory.
    nonisolated static let minimumLocalAIPhysicalMemoryBytes: UInt64 = 11 * 512 * 1024 * 1024
    nonisolated static var cloudComingSoonMessage: String {
        localizedAIText("on_device_ai_fallback_hint")
    }
    nonisolated static let eventPrefix = "STROPHE_AI_EVENT "

    nonisolated static func localizedAIText(_ key: String) -> String {
        NSLocalizedString(key, comment: "AI subtitle generation")
    }

    nonisolated static func localizedAIFormat(
        _ key: String,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: NSLocalizedString(key, comment: "AI subtitle generation"),
            arguments: arguments
        )
    }

    nonisolated static func localDeviceSupport() -> AIBackendAvailability {
        if ProcessInfo.processInfo.physicalMemory < minimumLocalAIPhysicalMemoryBytes {
            return .unavailable(unsupportedDeviceMessage)
        }

        #if os(macOS)
        if #available(macOS 15.0, *) {
            return .available
        } else {
            return .unavailable(unsupportedDeviceMessage)
        }
        #else
        if #available(iOS 18.0, *) {
            return .available
        } else {
            return .unavailable(unsupportedDeviceMessage)
        }
        #endif
    }

    nonisolated static var isLocalDeviceSupported: Bool {
        if case .available = localDeviceSupport() {
            return true
        }
        return false
    }

    nonisolated static func localAvailability() -> AIBackendAvailability {
        if case .unavailable(let reason) = localDeviceSupport() {
            return .unavailable(reason)
        }

        #if STROPHE_LOCAL_AI
        return .available
        #else
        #if arch(x86_64)
        return .unavailable(unsupportedDeviceMessage)
        #else
        #if os(macOS)
        if #available(macOS 15.0, *) {
            if helperExecutableURL() != nil {
                return .available
            }
            return .unavailable("本地 AI 后端已从主程序解耦，但尚未找到 StropheAIBackend helper。当前版本会保持核心功能可用，并暂时关闭本地 AI。")
        } else {
            return .unavailable("本地 AI 自动生成功能需要 iOS 18.0 或 macOS 15.0 以上系统；当前系统仍可使用字幕编辑、导入导出等核心功能。")
        }
        #else
        #if STROPHE_IOS_LOCAL_AI
        if #available(iOS 18.0, *) {
            return .available
        }
        return .unavailable(unsupportedDeviceMessage)
        #else
        if #available(iOS 18.0, *) {
            return .unavailable("iOS 本地 AI 后端尚未接入。当前版本会保持核心功能可用，并暂时关闭本地 AI。")
        } else {
            return .unavailable(unsupportedDeviceMessage)
        }
        #endif
        #endif
        #endif
        #endif
    }

    nonisolated static func ensureLocalAIAvailable() throws {
        switch localAvailability() {
        case .available:
            return
        case .unavailable(let reason):
            throw NSError(
                domain: "AIBackendClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: reason]
            )
        }
    }

    func generateSubtitles(
        request: AIGenerateSubtitlesRequest,
        progressCallback: (@Sendable (Int, Double, String) -> Void)? = nil
    ) async throws -> [AIResultSegment] {
        try Self.ensureLocalAIAvailable()
        #if STROPHE_LOCAL_AI
        #if os(macOS)
        if #available(macOS 15.0, *) {
            return try await runInProcess(
                request: request,
                progressCallback: progressCallback
            )
        }
        #else
        if #available(iOS 18.0, *) {
            return try await runInProcess(
                request: request,
                progressCallback: progressCallback
            )
        }
        #endif
        throw NSError(
            domain: "AIBackendClient",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: Self.unsupportedDeviceMessage]
        )
        #else
        #if os(macOS)
        guard let helperURL = Self.helperExecutableURL() else {
            throw NSError(
                domain: "AIBackendClient",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "未找到 StropheAIBackend helper。"]
            )
        }
        return try await runHelper(
            helperURL: helperURL,
            request: request,
            progressCallback: progressCallback
        )
        #else
        #if STROPHE_IOS_LOCAL_AI
        if #available(iOS 18.0, *) {
            return try await runInProcess(
                request: request,
                progressCallback: progressCallback
            )
        }
        throw NSError(
            domain: "AIBackendClient",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: Self.unsupportedDeviceMessage]
        )
        #else
        _ = request
        progressCallback?(
            0,
            0,
            Self.localizedAIText("error_on_device_ai_unsupported")
        )
        throw NSError(
            domain: "AIBackendClient",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey: Self.localizedAIText(
                    "error_on_device_ai_unsupported"
                )
            ]
        )
        #endif
        #endif
        #endif
    }

    #if STROPHE_LOCAL_AI
    @available(iOS 18.0, macOS 15.0, *)
    private func runInProcess(
        request: AIGenerateSubtitlesRequest,
        progressCallback: (@Sendable (Int, Double, String) -> Void)?
    ) async throws -> [AIResultSegment] {
        let modelStorageRoot = request.modelStorageRoot
        let hasModelStorageAccess = modelStorageRoot?.startAccessingSecurityScopedResource() ?? false
        #if os(macOS)
        if modelStorageRoot != nil && !hasModelStorageAccess {
            throw NSError(
                domain: "AIBackendClient.Storage",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "外置模型目录权限已失效，请在模型设置中重新选择该目录。"]
            )
        }
        #endif
        defer {
            if hasModelStorageAccess { modelStorageRoot?.stopAccessingSecurityScopedResource() }
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("strophe_ai_local_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        progressCallback?(
            0,
            0.03,
            Self.localizedAIText("status_decoding_media_audio")
        )
        let preparedAudio16kURL = temporaryDirectory.appendingPathComponent("input_16k.wav")
        let preparedSamples16k = try await AudioExtractor.extract(from: request.audioURL, targetSampleRate: 16000.0)
        try AudioExtractor.writeMonoWav(samples: preparedSamples16k, sampleRate: 16000.0, to: preparedAudio16kURL)

        let normalizedPreprocessing = request.vocalPreprocessing.lowercased()
        let preparedAudio48kURL: URL?
        if normalizedPreprocessing == "none" {
            preparedAudio48kURL = nil
        } else {
            progressCallback?(
                0,
                0.1,
                Self.localizedAIText("status_preparing_48k_audio")
            )
            let outputURL = temporaryDirectory.appendingPathComponent("input_48k.wav")
            let preparedSamples48k = try await AudioExtractor.extract(from: request.audioURL, targetSampleRate: 48000.0)
            try AudioExtractor.writeMonoWav(samples: preparedSamples48k, sampleRate: 48000.0, to: outputURL)
            preparedAudio48kURL = outputURL
        }

        return try await SubtitleGenerator().generateDiarizedSubtitles(
            preparedAudio16kURL: preparedAudio16kURL,
            preparedAudio48kURL: preparedAudio48kURL,
            asrModelName: request.asrModelName,
            whisperModelURL: request.whisperModelURL,
            asrDecoderModelURL: request.asrDecoderModelURL,
            alignerModelURL: request.alignerModelURL,
            vadModelURL: request.vadModelURL,
            speakerModelURL: request.speakerModelURL,
            whisperBaseDir: request.whisperBaseDir,
            alignerBaseDir: request.alignerBaseDir,
            speakerBaseDir: request.speakerBaseDir,
            alignerModelId: request.alignerModelId,
            modelStorageRoot: request.modelStorageRoot,
            expectedSpeakers: request.expectedSpeakers,
            language: request.language,
            enableDiarization: request.enableDiarization,
            prefixSpeakerName: request.prefixSpeakerName,
            enableAlignment: request.enableAlignment,
            vocalPreprocessing: request.vocalPreprocessing,
            referenceText: request.referenceText,
            useVAD: request.useVAD,
            progressCallback: progressCallback
        )
    }
    #endif
}
