//
//  AIBackendClient+Cloud.swift
//  Strophe
//
//  Created by Codex on 2026/06/04.
//

import Foundation
import Darwin

extension AIBackendClient {

    func testCloudConnection(
        baseURL: URL,
        model: AICloudASRModel
    ) async throws -> AICloudConnectionCheck {
        Self.triggerLocalNetworkPrivacyAlert(for: baseURL)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let healthURL = Self.cloudEndpointURL(baseURL: baseURL, path: "health")
        let healthResponse: CloudProbeResponse
        do {
            healthResponse = try await Self.performCloudProbe(url: healthURL, session: session)
        } catch {
            throw Self.userFacingCloudError(error)
        }
        guard (200...299).contains(healthResponse.statusCode) else {
            throw Self.cloudHTTPError(
                endpoint: "/health",
                statusCode: healthResponse.statusCode,
                responseBody: healthResponse.body
            )
        }

        let readyURL = try Self.cloudEndpointWithModelParam(
            Self.cloudEndpointURL(baseURL: baseURL, path: "ready"),
            model: model.rawValue
        )
        let readyResponse: CloudProbeResponse
        do {
            readyResponse = try await Self.performCloudProbe(url: readyURL, session: session)
        } catch {
            throw Self.userFacingCloudError(error)
        }
        guard (200...299).contains(readyResponse.statusCode) else {
            let detail = Self.limitedCloudResponseText(readyResponse.body)
            let suffix = detail.isEmpty
                ? ""
                : Self.localizedAIFormat("cloud_response_detail_format", detail)
            return AICloudConnectionCheck(
                isReady: false,
                message: Self.localizedAIFormat(
                    "cloud_service_not_ready_format",
                    model.displayName,
                    readyResponse.statusCode,
                    suffix
                )
            )
        }
        guard let readyPayload = try? JSONDecoder().decode(
            CloudReadyPayload.self,
            from: readyResponse.body
        ), readyPayload.status.lowercased() == "ready",
           readyPayload.model == model.rawValue else {
            return AICloudConnectionCheck(
                isReady: false,
                message: Self.localizedAIFormat(
                    "cloud_route_unconfirmed_format",
                    model.displayName
                )
            )
        }

        return AICloudConnectionCheck(
            isReady: true,
            message: Self.localizedAIFormat(
                "cloud_connection_success_format",
                model.displayName
            )
        )
    }

    func generateCloudSubtitles(
        request: AICloudGenerateSubtitlesRequest,
        progressCallback: (@Sendable (Int, Double, String) -> Void)? = nil
    ) async throws -> AICloudTranscriptionResult {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("strophe_ai_cloud_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        progressCallback?(
            0,
            0.05,
            Self.localizedAIText("status_preparing_cloud_audio")
        )
        let preparedAudio16kURL = temporaryDirectory.appendingPathComponent("input_16k_pcm.wav")
        let preparedSamples16k = try await AudioExtractor.extract(from: request.mediaURL, targetSampleRate: 16000.0)
        progressCallback?(
            0,
            0.85,
            Self.localizedAIText("status_writing_16k_wav")
        )
        try AudioExtractor.writeMonoPCM16Wav(samples: preparedSamples16k, sampleRate: 16000, to: preparedAudio16kURL)

        progressCallback?(
            1,
            0.05,
            Self.localizedAIText("status_uploading_cloud_audio")
        )
        let boundary = "StropheBoundary-\(UUID().uuidString)"
        let body = try Self.makeCloudMultipartBody(
            audioURL: preparedAudio16kURL,
            language: request.language,
            model: request.model.rawValue,
            enableKaraoke: request.enableKaraoke,
            boundary: boundary
        )
        var urlRequest = URLRequest(
            url: try Self.cloudEndpointWithStreamParam(
                request.endpointURL,
                language: request.language,
                model: request.model.rawValue,
                enableKaraoke: request.enableKaraoke
            )
        )
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

        let finalURL = urlRequest.url?.absoluteString ?? request.endpointURL.absoluteString
        print("[Strophe] Cloud transcription endpoint: \(finalURL)")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch {
            throw Self.userFacingCloudError(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "AIBackendClient",
                code: 20,
                userInfo: [
                    NSLocalizedDescriptionKey: Self.localizedAIText(
                        "error_cloud_invalid_response"
                    )
                ]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseText = try await Self.collectCloudErrorBody(from: bytes)
            let detail = responseText.isEmpty
                ? ""
                : Self.localizedAIFormat(
                    "cloud_response_detail_format",
                    responseText
                )
            let message = Self.localizedAIFormat(
                "error_cloud_http_status_format",
                httpResponse.statusCode,
                detail
            )
            throw NSError(
                domain: "AIBackendClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        progressCallback?(
            1,
            1.0,
            Self.localizedAIText("status_cloud_upload_complete")
        )

        var finalResult: AICloudTranscriptionResult?
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            switch try Self.decodeCloudLine(line) {
            case .progress(let progress, let message):
                progressCallback?(
                    2,
                    progress,
                    Self.localizedCloudProgressMessage(message)
                )
            case .result(let result):
                finalResult = result
                progressCallback?(
                    3,
                    0.4,
                    Self.localizedAIText("status_organizing_cloud_subtitles")
                )
            case .error(let message):
                throw NSError(
                    domain: "AIBackendClient",
                    code: 21,
                    userInfo: [
                        NSLocalizedDescriptionKey: message.isEmpty
                            ? Self.localizedAIText("error_cloud_service")
                            : message
                    ]
                )
            case .ignored:
                continue
            }
        }

        guard let finalResult else {
            throw NSError(
                domain: "AIBackendClient",
                code: 22,
                userInfo: [
                    NSLocalizedDescriptionKey: Self.localizedAIText(
                        "error_cloud_no_result"
                    )
                ]
            )
        }

        guard finalResult.model == request.model.rawValue else {
            let actual = finalResult.model ?? "missing"
            throw NSError(
                domain: "AIBackendClient",
                code: 32,
                userInfo: [
                    NSLocalizedDescriptionKey: Self.localizedAIFormat(
                        "error_cloud_model_mismatch_format",
                        actual,
                        request.model.rawValue
                    )
                ]
            )
        }

        guard !finalResult.segments.isEmpty else {
            throw NSError(
                domain: "AIBackendClient",
                code: 23,
                userInfo: [
                    NSLocalizedDescriptionKey: Self.localizedAIText(
                        "error_cloud_empty_subtitles"
                    )
                ]
            )
        }

        progressCallback?(
            3,
            1.0,
            Self.localizedAIText("status_cloud_results_received")
        )
        return finalResult
    }

    static func localizedCloudProgressMessage(_ serverMessage: String) -> String {
        let range = NSRange(serverMessage.startIndex..., in: serverMessage)
        if let expression = try? NSRegularExpression(
            pattern: #"(\d+)\s*/\s*(\d+)"#
        ),
           let match = expression.firstMatch(in: serverMessage, range: range),
           let currentRange = Range(match.range(at: 1), in: serverMessage),
           let totalRange = Range(match.range(at: 2), in: serverMessage),
           let current = Int(serverMessage[currentRange]),
           let total = Int(serverMessage[totalRange]) {
            return localizedAIFormat(
                "status_cloud_recognizing_segment_format",
                current,
                total
            )
        }
        return localizedAIText("status_cloud_recognizing")
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
        let model: String?
        let timestampsSentence: [CloudTimestamp]?
        let timestampsWord: [CloudTimestamp]?
        let srt: String?

        private enum CodingKeys: String, CodingKey {
            case status
            case language
            case model
            case timestampsSentence = "timestamps_sentence"
            case timestampsWord = "timestamps_word"
            case srt
        }
    }

    struct CloudReadyPayload: Decodable {
        let status: String
        let model: String
    }

    struct CloudTimestamp: Decodable {
        let start: Double
        let end: Double
        let text: String
    }

    static func cloudEndpointWithStreamParam(
        _ endpointURL: URL,
        language: String,
        model: String,
        enableKaraoke: Bool = false
    ) throws -> URL {
        guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
            throw NSError(
                domain: "AIBackendClient",
                code: 24,
                userInfo: [
                    NSLocalizedDescriptionKey: localizedAIText(
                        "error_cloud_address_invalid_short"
                    )
                ]
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
        if !queryItems.contains(where: { $0.name == "model" }) {
            queryItems.append(URLQueryItem(name: "model", value: model))
        }
        if enableKaraoke {
            queryItems.append(URLQueryItem(name: "word_timestamps", value: "true"))
            queryItems.append(URLQueryItem(name: "forced_alignment", value: "true"))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw NSError(
                domain: "AIBackendClient",
                code: 25,
                userInfo: [
                    NSLocalizedDescriptionKey: localizedAIText(
                        "error_cloud_request_url_failed"
                    )
                ]
            )
        }
        return url
    }

    static func cloudEndpointWithModelParam(
        _ endpointURL: URL,
        model: String
    ) throws -> URL {
        guard var components = URLComponents(
            url: endpointURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw NSError(
                domain: "AIBackendClient",
                code: 28,
                userInfo: [
                    NSLocalizedDescriptionKey: localizedAIText(
                        "error_cloud_ready_url_failed"
                    )
                ]
            )
        }
        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "model" }) {
            queryItems.append(URLQueryItem(name: "model", value: model))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw NSError(
                domain: "AIBackendClient",
                code: 29,
                userInfo: [
                    NSLocalizedDescriptionKey: localizedAIText(
                        "error_cloud_ready_url_failed"
                    )
                ]
            )
        }
        return url
    }

    struct CloudProbeResponse {
        let statusCode: Int
        let body: Data
    }

    /// A connected UDP socket performs no I/O, but it asks macOS to resolve the
    /// app's Local Network privilege before the HTTP health check starts.
    nonisolated static func triggerLocalNetworkPrivacyAlert(for baseURL: URL) {
        guard let host = baseURL.host else { return }
        let port = UInt16(baseURL.port ?? (baseURL.scheme?.lowercased() == "https" ? 443 : 80))

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &destination.sin_addr) == 1 else { return }

        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }

        let destinationLength = socklen_t(destination.sin_len)
        withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                _ = Darwin.connect(descriptor, address, destinationLength)
            }
        }
    }

    static func performCloudProbe(url: URL, session: URLSession) async throws -> CloudProbeResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        print("[Strophe] Cloud connection probe: \(url.absoluteString)")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "AIBackendClient.CloudConnection",
                code: 30,
                userInfo: [
                    NSLocalizedDescriptionKey: localizedAIText(
                        "error_cloud_invalid_response"
                    )
                ]
            )
        }
        return CloudProbeResponse(statusCode: httpResponse.statusCode, body: data)
    }

    nonisolated static func cloudHTTPError(
        endpoint: String,
        statusCode: Int,
        responseBody: Data
    ) -> NSError {
        let detail = limitedCloudResponseText(responseBody)
        let suffix = detail.isEmpty
            ? ""
            : localizedAIFormat("cloud_response_detail_format", detail)
        return NSError(
            domain: "AIBackendClient.CloudConnection",
            code: statusCode,
            userInfo: [
                NSLocalizedDescriptionKey: localizedAIFormat(
                    "error_cloud_endpoint_http_format",
                    endpoint,
                    statusCode,
                    suffix
                )
            ]
        )
    }

    nonisolated static func limitedCloudResponseText(_ data: Data, limit: Int = 2048) -> String {
        let prefix = data.prefix(limit)
        return String(decoding: prefix, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func userFacingCloudError(_ error: Error) -> NSError {
        let nsError = error as NSError
        if nsError.domain == "AIBackendClient.CloudConnection"
            || nsError.domain == "AIBackendClient.CloudConfiguration" {
            return nsError
        }

        let diagnostics = ([nsError.localizedDescription] + nsError.userInfo.values.map(String.init(describing:)))
            .joined(separator: " ")
            .lowercased()
        if diagnostics.contains("local network prohibited")
            || diagnostics.contains("local network denied") {
            return NSError(
                domain: "AIBackendClient.CloudConnection",
                code: nsError.code,
                userInfo: [
                    NSLocalizedDescriptionKey: localizedAIText(
                        "error_cloud_local_network_denied"
                    )
                ]
            )
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost:
                let message = containsPOSIXError(nsError, code: .ECONNREFUSED)
                    ? localizedAIText("error_cloud_connection_refused")
                    : localizedAIText("error_cloud_cannot_connect")
                return NSError(
                    domain: "AIBackendClient.CloudConnection",
                    code: urlError.errorCode,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            case .timedOut:
                return NSError(
                    domain: "AIBackendClient.CloudConnection",
                    code: urlError.errorCode,
                    userInfo: [
                        NSLocalizedDescriptionKey: localizedAIText(
                            "error_cloud_connection_timeout"
                        )
                    ]
                )
            case .cannotFindHost, .dnsLookupFailed:
                return NSError(
                    domain: "AIBackendClient.CloudConnection",
                    code: urlError.errorCode,
                    userInfo: [
                        NSLocalizedDescriptionKey: localizedAIText(
                            "error_cloud_host_not_found"
                        )
                    ]
                )
            case .networkConnectionLost:
                return NSError(
                    domain: "AIBackendClient.CloudConnection",
                    code: urlError.errorCode,
                    userInfo: [
                        NSLocalizedDescriptionKey: localizedAIText(
                            "error_cloud_connection_lost"
                        )
                    ]
                )
            case .notConnectedToInternet:
                return NSError(
                    domain: "AIBackendClient.CloudConnection",
                    code: urlError.errorCode,
                    userInfo: [
                        NSLocalizedDescriptionKey: localizedAIText(
                            "error_network_unavailable"
                        )
                    ]
                )
            default:
                break
            }
        }

        return nsError
    }

    nonisolated static func containsPOSIXError(_ error: NSError, code: POSIXErrorCode) -> Bool {
        if error.domain == NSPOSIXErrorDomain && error.code == Int(code.rawValue) {
            return true
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        return containsPOSIXError(underlying, code: code)
    }

    static func makeCloudMultipartBody(
        audioURL: URL,
        language: String,
        model: String,
        enableKaraoke: Bool = false,
        boundary: String
    ) throws -> Data {
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
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        if enableKaraoke {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"word_timestamps\"\r\n\r\n")
            append("true\r\n")

            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"forced_alignment\"\r\n\r\n")
            append("true\r\n")
        }

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
                        userInfo: [
                            NSLocalizedDescriptionKey: localizedAIText(
                                "error_cloud_invalid_response"
                            )
                        ]
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
                userInfo: [
                    NSLocalizedDescriptionKey: localizedAIFormat(
                        "error_cloud_status_format",
                        status
                    )
                ]
            )
        }

        let words = wordTimings(from: payload.timestampsWord)
        var segments = timestampSegments(from: payload.timestampsSentence)
        if !segments.isEmpty, !words.isEmpty {
            segments = segments.map { segment in
                let segmentWords = words.filter {
                    $0.endTime > segment.startTime && $0.startTime < segment.endTime
                }
                return AIResultSegment(
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    words: segmentWords
                )
            }
        } else if segments.isEmpty, !words.isEmpty {
            segments = SubtitleSegmentation.makeSegments(words: words)
        }
        if segments.isEmpty, let srt = payload.srt {
            segments = parseCloudSRTSegments(srt)
        }

        return AICloudTranscriptionResult(
            language: payload.language,
            model: payload.model,
            segments: segments
        )
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

    static func wordTimings(from timestamps: [CloudTimestamp]?) -> [SubtitleWordTiming] {
        guard let timestamps else { return [] }
        return timestamps.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard item.start.isFinite, item.end.isFinite,
                  item.end > item.start, !text.isEmpty else { return nil }
            return SubtitleWordTiming(
                text: text,
                startTime: item.start,
                endTime: item.end
            )
        }
        .sorted { $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime }
    }

    static func normalizedCloudProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        let normalized = progress > 1.0 ? progress / 100.0 : progress
        return min(1.0, max(0.0, normalized))
    }
}
