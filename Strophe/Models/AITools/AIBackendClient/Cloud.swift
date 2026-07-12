//
//  AIBackendClient+Cloud.swift
//  Strophe
//
//  Created by Codex on 2026/06/04.
//

import Foundation

extension AIBackendClient {

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

    enum CloudLine {
        case progress(Double, String)
        case result(AICloudTranscriptionResult)
        case error(String)
        case ignored
    }

    struct CloudStreamEvent: Decodable {
        let type: String?
        let progress: Double?
        let message: String?
        let data: CloudTranscriptionPayload?
    }

    struct CloudTranscriptionPayload: Decodable {
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

    struct CloudTimestamp: Decodable {
        let start: Double
        let end: Double
        let text: String
    }

    static func cloudEndpointWithStreamParam(_ endpointURL: URL, language: String) throws -> URL {
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

    static func makeCloudMultipartBody(audioURL: URL, language: String, boundary: String) throws -> Data {
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

    static func collectCloudErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
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

    static func decodeCloudLine(_ line: String) throws -> CloudLine {
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

    static func cloudResult(from payload: CloudTranscriptionPayload) throws -> AICloudTranscriptionResult {
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

    static func parseCloudSRTSegments(_ srt: String) -> [AIResultSegment] {
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

    static func parseCloudSRTTimestamp(_ timestamp: String) -> Double? {
        let parts = timestamp.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    static func timestampSegments(from timestamps: [CloudTimestamp]?) -> [AIResultSegment] {
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

    static func normalizedCloudProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        let normalized = progress > 1.0 ? progress / 100.0 : progress
        return min(1.0, max(0.0, normalized))
    }
}
