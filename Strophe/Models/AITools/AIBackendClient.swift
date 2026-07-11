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
    let useVAD: Bool
}

struct AICloudGenerateSubtitlesRequest: Sendable {
    let mediaURL: URL
    let endpointURL: URL
    let language: String
}

struct AICloudTranscriptionResult: Sendable {
    let language: String?
    let segments: [AIResultSegment]
}

enum AIBackendAvailability: Sendable {
    case available
    case unavailable(String)
}

actor AIBackendClient {
    static let shared = AIBackendClient()
    nonisolated static let defaultCloudBaseURL = URL(string: "http://192.168.10.10:8000")!
    nonisolated static var defaultCloudTranscribeURL: URL {
        defaultCloudBaseURL.appendingPathComponent("transcribe")
    }
    #if STROPHE_LOCAL_AI
    nonisolated static let isLocalAIIncludedInBuild = true
    #else
    nonisolated static let isLocalAIIncludedInBuild = false
    #endif
    nonisolated static let unsupportedDeviceMessage = "您的设备不支持本地AI运行"
    nonisolated static let cloudComingSoonMessage = "可以使用云端生成字幕，或在支持设备上使用本地生成。"
    private nonisolated static let eventPrefix = "STROPHE_AI_EVENT "

    nonisolated static func localDeviceSupport() -> AIBackendAvailability {
        if ProcessInfo.processInfo.physicalMemory < 3_700_000_000 {
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
        progressCallback?(0, 0, "iOS 本地 AI 后端尚未接入。")
        throw NSError(
            domain: "AIBackendClient",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "iOS 本地 AI 后端尚未接入。"]
        )
        #endif
        #endif
        #endif
    }

    func generateCloudSubtitles(
        request: AICloudGenerateSubtitlesRequest,
        progressCallback: (@Sendable (Int, Double, String) -> Void)? = nil
    ) async throws -> AICloudTranscriptionResult {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("strophe_ai_cloud_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        progressCallback?(0, 0.05, "正在准备云端识别音频...")
        let preparedAudio16kURL = temporaryDirectory.appendingPathComponent("input_16k_pcm.wav")
        let preparedSamples16k = try await AudioExtractor.extract(from: request.mediaURL, targetSampleRate: 16000.0)
        progressCallback?(0, 0.85, "正在写入 16k 单声道 WAV...")
        try AudioExtractor.writeMonoPCM16Wav(samples: preparedSamples16k, sampleRate: 16000, to: preparedAudio16kURL)

        progressCallback?(1, 0.05, "正在上传音频到云端识别服务...")
        let boundary = "StropheBoundary-\(UUID().uuidString)"
        let body = try Self.makeCloudMultipartBody(audioURL: preparedAudio16kURL, language: request.language, boundary: boundary)
        var urlRequest = URLRequest(url: try Self.cloudEndpointWithStreamParam(request.endpointURL, language: request.language))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = 3600

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "AIBackendClient",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "云端识别服务返回了无效响应。"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseText = try await Self.collectCloudErrorBody(from: bytes)
            let message = responseText.isEmpty
                ? "云端识别服务返回 HTTP \(httpResponse.statusCode)。"
                : "云端识别服务返回 HTTP \(httpResponse.statusCode)：\(responseText)"
            throw NSError(
                domain: "AIBackendClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        progressCallback?(1, 1.0, "音频上传完成，等待云端识别...")

        var finalResult: AICloudTranscriptionResult?
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            switch try Self.decodeCloudLine(line) {
            case .progress(let progress, let message):
                progressCallback?(2, progress, message.isEmpty ? "云端正在识别与对齐..." : message)
            case .result(let result):
                finalResult = result
                progressCallback?(3, 0.4, "正在整理云端返回的字幕...")
            case .error(let message):
                throw NSError(
                    domain: "AIBackendClient",
                    code: 21,
                    userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "云端识别服务返回错误。" : message]
                )
            case .ignored:
                continue
            }
        }

        guard let finalResult else {
            throw NSError(
                domain: "AIBackendClient",
                code: 22,
                userInfo: [NSLocalizedDescriptionKey: "云端识别服务未返回字幕结果。"]
            )
        }

        guard !finalResult.segments.isEmpty else {
            throw NSError(
                domain: "AIBackendClient",
                code: 23,
                userInfo: [NSLocalizedDescriptionKey: "云端识别服务返回了空字幕。"]
            )
        }

        progressCallback?(3, 1.0, "云端字幕结果已接收。")
        return finalResult
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

    private enum CloudLine {
        case progress(Double, String)
        case result(AICloudTranscriptionResult)
        case error(String)
        case ignored
    }

    private struct CloudStreamEvent: Decodable {
        let type: String?
        let progress: Double?
        let message: String?
        let data: CloudTranscriptionPayload?
    }

    private struct CloudTranscriptionPayload: Decodable {
        let status: String?
        let language: String?
        let timestampsSentence: [CloudTimestamp]?
        let timestampsWord: [CloudTimestamp]?
        let srt: String?

        private enum CodingKeys: String, CodingKey {
            case status
            case language
            case timestampsSentence = "timestamps_sentence"
            case timestampsWord = "timestamps_word"
            case srt
        }
    }

    private struct CloudTimestamp: Decodable {
        let start: Double
        let end: Double
        let text: String
    }

    private static func cloudEndpointWithStreamParam(_ endpointURL: URL, language: String) throws -> URL {
        guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
            throw NSError(
                domain: "AIBackendClient",
                code: 24,
                userInfo: [NSLocalizedDescriptionKey: "云端识别服务地址无效。"]
            )
        }

        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "stream" }) {
            queryItems.append(URLQueryItem(name: "stream", value: "true"))
        }
        if !queryItems.contains(where: { $0.name == "language" }) {
            queryItems.append(URLQueryItem(name: "language", value: language))
        }
        if !queryItems.contains(where: { $0.name == "lang" }) {
            queryItems.append(URLQueryItem(name: "lang", value: language))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw NSError(
                domain: "AIBackendClient",
                code: 25,
                userInfo: [NSLocalizedDescriptionKey: "无法构造云端识别请求地址。"]
            )
        }
        return url
    }

    private static func makeCloudMultipartBody(audioURL: URL, language: String, boundary: String) throws -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
        append("\(language)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"lang\"\r\n\r\n")
        append("\(language)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        append("\r\n--\(boundary)--\r\n")

        return body
    }

    private static func collectCloudErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var lines: [String] = []
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(trimmed)
            if lines.joined(separator: "\n").count > 4096 {
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func decodeCloudLine(_ line: String) throws -> CloudLine {
        guard let data = line.data(using: .utf8) else { return .ignored }
        let decoder = JSONDecoder()

        if let event = try? decoder.decode(CloudStreamEvent.self, from: data),
           let eventType = event.type {
            switch eventType {
            case "progress":
                return .progress(normalizedCloudProgress(event.progress ?? 0), event.message ?? "")
            case "result":
                guard let payload = event.data else {
                    throw NSError(
                        domain: "AIBackendClient",
                        code: 26,
                        userInfo: [NSLocalizedDescriptionKey: "云端识别结果缺少 data 字段。"]
                    )
                }
                return .result(try cloudResult(from: payload))
            case "error":
                return .error(event.message ?? "")
            default:
                return .ignored
            }
        }

        if let payload = try? decoder.decode(CloudTranscriptionPayload.self, from: data) {
            return .result(try cloudResult(from: payload))
        }

        return .ignored
    }

    private static func cloudResult(from payload: CloudTranscriptionPayload) throws -> AICloudTranscriptionResult {
        if let status = payload.status, status.lowercased() != "success" {
            throw NSError(
                domain: "AIBackendClient",
                code: 27,
                userInfo: [NSLocalizedDescriptionKey: "云端识别未成功：\(status)"]
            )
        }

        var segments = timestampSegments(from: payload.timestampsSentence)
        if segments.isEmpty {
            segments = timestampSegments(from: payload.timestampsWord)
        }
        if segments.isEmpty, let srt = payload.srt {
            segments = parseCloudSRTSegments(srt)
        }

        return AICloudTranscriptionResult(language: payload.language, segments: segments)
    }

    private static func parseCloudSRTSegments(_ srt: String) -> [AIResultSegment] {
        let normalizedText = srt.replacingOccurrences(of: "\r\n", with: "\n")
        let chunks = normalizedText.components(separatedBy: "\n\n")
        let pattern = #"(\d{2}:\d{2}:\d{2}[\.,]\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}[\.,]\d{3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        return chunks.compactMap { chunk -> AIResultSegment? in
            let lines = chunk
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard lines.count >= 3 else { return nil }

            let timeLine = lines[1]
            let range = NSRange(timeLine.startIndex..<timeLine.endIndex, in: timeLine)
            guard let match = regex.firstMatch(in: timeLine, range: range),
                  let startRange = Range(match.range(at: 1), in: timeLine),
                  let endRange = Range(match.range(at: 2), in: timeLine),
                  let start = parseCloudSRTTimestamp(String(timeLine[startRange])),
                  let end = parseCloudSRTTimestamp(String(timeLine[endRange])),
                  end > start else {
                return nil
            }

            let text = lines[2...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return AIResultSegment(text: text, startTime: start, endTime: end)
        }
    }

    private static func parseCloudSRTTimestamp(_ timestamp: String) -> Double? {
        let parts = timestamp.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func timestampSegments(from timestamps: [CloudTimestamp]?) -> [AIResultSegment] {
        guard let timestamps else { return [] }
        return timestamps.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard item.start.isFinite, item.end.isFinite, item.end > item.start, !text.isEmpty else {
                return nil
            }
            return AIResultSegment(text: text, startTime: item.start, endTime: item.end)
        }
        .sorted { first, second in
            if first.startTime == second.startTime {
                return first.endTime < second.endTime
            }
            return first.startTime < second.startTime
        }
    }

    private static func normalizedCloudProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        let normalized = progress > 1.0 ? progress / 100.0 : progress
        return min(1.0, max(0.0, normalized))
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
            useVAD: request.useVAD,
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
        let useVAD: Bool
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
            referenceText: request.referenceText,
            useVAD: request.useVAD
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
