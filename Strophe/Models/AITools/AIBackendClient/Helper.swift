//
//  AIBackendClient+Helper.swift
//  Strophe
//
//  Created by Codex on 2026/06/04.
//

import Foundation

#if os(macOS)
extension AIBackendClient {

    nonisolated static func helperExecutableURL() -> URL? {
        let fm = FileManager.default

        if let override = ProcessInfo.processInfo.environment["STROPHE_AI_BACKEND_PATH"],
           !override.isEmpty,
           fm.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

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

        return nil
    }

    struct HelperRequest: Encodable {
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

    func runHelper(
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

    struct ResultPayload: Decodable {
        let segments: [SegmentPayload]
    }

    struct SegmentPayload: Decodable {
        let text: String
        let startTime: Double
        let endTime: Double
    }
}
#endif
