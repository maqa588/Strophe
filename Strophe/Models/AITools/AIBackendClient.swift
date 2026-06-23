//
//  AIBackendClient.swift
//  Strophe
//
//  Created by Codex on 2026/06/04.
//

import Foundation

struct AIGenerateSubtitlesRequest: Sendable {
    let audioURL: URL
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
}

enum AIBackendAvailability: Sendable {
    case available
    case unavailable(String)
}

actor AIBackendClient {
    static let shared = AIBackendClient()
    #if STROPHE_LITE
    nonisolated static let unsupportedDeviceMessage = "您使用的是 Strophe Lite（活字轻量版），无法使用本地 AI 功能。如果您的设备支持，请安装 Strophe 完整版，或者等待云端 AI 功能实现。"
    nonisolated static let cloudComingSoonMessage = unsupportedDeviceMessage
    #else
    nonisolated static let unsupportedDeviceMessage = "您的设备不支持本地AI运行"
    nonisolated static let cloudComingSoonMessage = "您的设备不支持本地AI运行，我们未来会为您的设备推出云端AI处理功能，敬请期待"
    #endif
    private nonisolated static let eventPrefix = "STROPHE_AI_EVENT "

    nonisolated static func localDeviceSupport() -> AIBackendAvailability {
        #if STROPHE_LITE
        return .unavailable(unsupportedDeviceMessage)
        #else
        if ProcessInfo.processInfo.physicalMemory < 3_700_000_000 {
            return .unavailable(unsupportedDeviceMessage)
        }

        #if arch(x86_64)
        return .unavailable(unsupportedDeviceMessage)
        #else
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
        #endif
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
        #if STROPHE_LITE
        _ = request
        progressCallback?(0, 0, Self.unsupportedDeviceMessage)
        throw NSError(
            domain: "AIBackendClient",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: Self.unsupportedDeviceMessage]
        )
        #else
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
        progressCallback?(0, 0, "iOS 本地 AI 后端尚未接入。")
        throw NSError(
            domain: "AIBackendClient",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "iOS 本地 AI 后端尚未接入。"]
        )
        #endif
        #endif
        #endif
        #endif
    }

    nonisolated private static func helperExecutableURL() -> URL? {
        let fm = FileManager.default

        if let override = ProcessInfo.processInfo.environment["STROPHE_AI_BACKEND_PATH"],
           !override.isEmpty,
           fm.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        #if os(macOS)
        let bundleCandidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("StropheAIBackend"),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent("StropheAIBackend")
        ]

        for candidate in bundleCandidates where fm.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        #endif

        return nil
    }

    #if STROPHE_LOCAL_AI
    @available(iOS 18.0, macOS 15.0, *)
    private func runInProcess(
        request: AIGenerateSubtitlesRequest,
        progressCallback: (@Sendable (Int, Double, String) -> Void)?
    ) async throws -> [AIResultSegment] {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("strophe_ai_local_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        progressCallback?(0, 0.03, "正在由主程序解码媒体音频...")
        let preparedAudio16kURL = temporaryDirectory.appendingPathComponent("input_16k.wav")
        let preparedSamples16k = try await AudioExtractor.extract(from: request.audioURL, targetSampleRate: 16000.0)
        try AudioExtractor.writeMonoWav(samples: preparedSamples16k, sampleRate: 16000.0, to: preparedAudio16kURL)

        let normalizedPreprocessing = request.vocalPreprocessing.lowercased()
        let preparedAudio48kURL: URL?
        if normalizedPreprocessing == "none" {
            preparedAudio48kURL = nil
        } else {
            progressCallback?(0, 0.1, "正在准备 48kHz 人声预处理音频...")
            let outputURL = temporaryDirectory.appendingPathComponent("input_48k.wav")
            let preparedSamples48k = try await AudioExtractor.extract(from: request.audioURL, targetSampleRate: 48000.0)
            try AudioExtractor.writeMonoWav(samples: preparedSamples48k, sampleRate: 48000.0, to: outputURL)
            preparedAudio48kURL = outputURL
        }

        return try await SubtitleGenerator().generateDiarizedSubtitles(
            preparedAudio16kURL: preparedAudio16kURL,
            preparedAudio48kURL: preparedAudio48kURL,
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
            progressCallback: progressCallback
        )
    }
    #endif

    #if os(macOS)
    private struct HelperRequest: Encodable {
        let preparedAudio16kPath: String
        let preparedAudio48kPath: String?
        let whisperModelPath: String
        let asrDecoderModelPath: String?
        let alignerModelPath: String
        let vadModelPath: String
        let speakerModelPath: String
        let whisperBaseDir: String
        let alignerBaseDir: String
        let speakerBaseDir: String
        let alignerModelId: String
        let modelStorageRoot: String?
        let expectedSpeakers: Int?
        let language: String
        let enableDiarization: Bool
        let prefixSpeakerName: Bool
        let enableAlignment: Bool
        let vocalPreprocessing: String
        let referenceText: String?
    }

    private func runHelper(
        helperURL: URL,
        request: AIGenerateSubtitlesRequest,
        progressCallback: (@Sendable (Int, Double, String) -> Void)?
    ) async throws -> [AIResultSegment] {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("strophe_ai_client_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        progressCallback?(0, 0.03, "正在由主程序解码媒体音频...")
        let preparedAudio16kURL = temporaryDirectory.appendingPathComponent("input_16k.wav")
        let preparedSamples16k = try await AudioExtractor.extract(from: request.audioURL, targetSampleRate: 16000.0)
        try AudioExtractor.writeMonoWav(samples: preparedSamples16k, sampleRate: 16000.0, to: preparedAudio16kURL)

        let normalizedPreprocessing = request.vocalPreprocessing.lowercased()
        let preparedAudio48kURL: URL?
        if normalizedPreprocessing == "none" {
            preparedAudio48kURL = nil
        } else {
            progressCallback?(0, 0.1, "正在准备 48kHz 人声预处理音频...")
            let outputURL = temporaryDirectory.appendingPathComponent("input_48k.wav")
            let preparedSamples48k = try await AudioExtractor.extract(from: request.audioURL, targetSampleRate: 48000.0)
            try AudioExtractor.writeMonoWav(samples: preparedSamples48k, sampleRate: 48000.0, to: outputURL)
            preparedAudio48kURL = outputURL
        }

        let helperRequest = HelperRequest(
            preparedAudio16kPath: preparedAudio16kURL.path,
            preparedAudio48kPath: preparedAudio48kURL?.path,
            whisperModelPath: request.whisperModelURL.path,
            asrDecoderModelPath: request.asrDecoderModelURL?.path,
            alignerModelPath: request.alignerModelURL.path,
            vadModelPath: request.vadModelURL.path,
            speakerModelPath: request.speakerModelURL.path,
            whisperBaseDir: request.whisperBaseDir.path,
            alignerBaseDir: request.alignerBaseDir.path,
            speakerBaseDir: request.speakerBaseDir.path,
            alignerModelId: request.alignerModelId,
            modelStorageRoot: request.modelStorageRoot?.path,
            expectedSpeakers: request.expectedSpeakers,
            language: request.language,
            enableDiarization: request.enableDiarization,
            prefixSpeakerName: request.prefixSpeakerName,
            enableAlignment: request.enableAlignment,
            vocalPreprocessing: request.vocalPreprocessing,
            referenceText: request.referenceText
        )

        let requestURL = temporaryDirectory.appendingPathComponent("request.json")
        let requestData = try JSONEncoder().encode(helperRequest)
        try requestData.write(to: requestURL, options: .atomic)

        let process = Process()
        process.executableURL = helperURL
        process.arguments = [requestURL.path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        var finalSegments: [AIResultSegment]?
        var helperError: String?

        for try await rawLine in stdout.fileHandleForReading.bytes.lines {
            guard rawLine.hasPrefix(Self.eventPrefix) else { continue }
            let jsonLine = String(rawLine.dropFirst(Self.eventPrefix.count))
            guard let data = jsonLine.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }

            switch type {
            case "progress":
                let step = payload["step"] as? Int ?? 0
                let progress = payload["progress"] as? Double ?? 0
                let message = payload["message"] as? String ?? ""
                progressCallback?(step, progress, message)
            case "result":
                let payloadData = try JSONSerialization.data(withJSONObject: payload)
                let decoded = try JSONDecoder().decode(ResultPayload.self, from: payloadData)
                finalSegments = decoded.segments.map {
                    AIResultSegment(text: $0.text, startTime: $0.startTime, endTime: $0.endTime)
                }
            case "error":
                helperError = payload["message"] as? String
            default:
                break
            }
        }

        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "AIBackendClient",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: helperError ?? stderrText ?? "StropheAIBackend 执行失败。"
                ]
            )
        }

        if let helperError {
            throw NSError(
                domain: "AIBackendClient",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: helperError]
            )
        }

        return finalSegments ?? []
    }

    private struct ResultPayload: Decodable {
        let segments: [SegmentPayload]
    }

    private struct SegmentPayload: Decodable {
        let text: String
        let startTime: Double
        let endTime: Double
    }
    #endif
}
