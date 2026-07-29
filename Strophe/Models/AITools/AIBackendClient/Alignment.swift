import Foundation

extension AIBackendClient {
    private struct CloudAlignmentPayload: Decodable {
        let status: String?
        let cues: [CloudAlignedCue]
    }

    private struct CloudAlignedCue: Decodable {
        let id: UUID
        let words: [CloudAlignedWord]
    }

    private struct CloudAlignedWord: Decodable {
        let text: String
        let start: Double
        let end: Double
        let confidence: Double?
    }

    /// Calls the alignment-only route. This request deliberately has no ASR
    /// model field: the server receives authoritative cue text and only runs
    /// Qwen3-ForcedAligner.
    func alignCloudSubtitles(
        mediaURL: URL,
        endpointURL: URL,
        cues: [AICloudAlignmentCue],
        language: String,
        progressCallback: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> AICloudAlignmentResult {
        guard !cues.isEmpty else {
            return AICloudAlignmentResult(wordsByCueID: [:])
        }

        progressCallback?(0.05, Self.localizedAIText("status_preparing_cloud_audio"))
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("strophe_cloud_align_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let wavURL = temporaryDirectory.appendingPathComponent("input_16k_pcm.wav")
        let samples = try await AudioExtractor.extract(from: mediaURL, targetSampleRate: 16_000)
        try AudioExtractor.writeMonoPCM16Wav(samples: samples, sampleRate: 16_000, to: wavURL)

        let boundary = "StropheAlignBoundary-\(UUID().uuidString)"
        let cuesData = try JSONEncoder().encode(cues)
        guard let cuesJSON = String(data: cuesData, encoding: .utf8) else {
            throw NSError(domain: "AIBackendClient.Alignment", code: 1, userInfo: [
                NSLocalizedDescriptionKey: Self.localizedAIText("error_cloud_invalid_response")
            ])
        }
        let body = try Self.makeCloudAlignmentBody(
            audioURL: wavURL,
            cuesJSON: cuesJSON,
            language: language,
            boundary: boundary
        )

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 3600

        progressCallback?(0.25, Self.localizedAIText("status_uploading_cloud_audio"))
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.userFacingCloudError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "AIBackendClient.Alignment", code: 2, userInfo: [
                NSLocalizedDescriptionKey: Self.localizedAIText("error_cloud_invalid_response")
            ])
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.cloudHTTPError(
                endpoint: "/align",
                statusCode: http.statusCode,
                responseBody: data
            )
        }

        progressCallback?(0.9, Self.localizedAIText("status_organizing_cloud_subtitles"))
        let payload = try JSONDecoder().decode(CloudAlignmentPayload.self, from: data)
        guard payload.status?.lowercased() != "error" else {
            throw NSError(domain: "AIBackendClient.Alignment", code: 3, userInfo: [
                NSLocalizedDescriptionKey: Self.localizedAIText("error_cloud_service")
            ])
        }

        var result: [UUID: [SubtitleWordTiming]] = [:]
        for cue in payload.cues {
            result[cue.id] = cue.words.compactMap { word in
                guard word.start.isFinite, word.end.isFinite, word.end > word.start else {
                    return nil
                }
                return SubtitleWordTiming(
                    text: word.text,
                    startTime: word.start,
                    endTime: word.end,
                    confidence: word.confidence
                )
            }
        }
        progressCallback?(1, Self.localizedAIText("status_organizing_cloud_subtitles"))
        return AICloudAlignmentResult(wordsByCueID: result)
    }

    private static func makeCloudAlignmentBody(
        audioURL: URL,
        cuesJSON: String,
        language: String,
        boundary: String
    ) throws -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
        append("\(language)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"cues\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        append("\(cuesJSON)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}
