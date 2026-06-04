//
//  main.swift
//  StropheAIBackend
//
//  Created by Codex on 2026/06/04.
//

import Foundation

private struct BackendRequest: Decodable {
    let preparedAudio16kPath: String
    let preparedAudio48kPath: String?
    let whisperModelPath: String
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

private struct BackendEvent<T: Encodable>: Encodable {
    let type: String
    let payload: T
}

private struct ProgressPayload: Encodable {
    let step: Int
    let progress: Double
    let message: String
}

private struct SegmentPayload: Encodable {
    let text: String
    let startTime: Double
    let endTime: Double
}

private struct ResultPayload: Encodable {
    let segments: [SegmentPayload]
}

private struct ErrorPayload: Encodable {
    let message: String
}

private let eventPrefix = "STROPHE_AI_EVENT "

private func emit<T: Encodable>(_ type: String, _ payload: T) {
    let event = BackendEvent(type: type, payload: payload)
    guard let data = try? JSONEncoder().encode(event),
          let json = String(data: data, encoding: .utf8) else {
        return
    }
    print(eventPrefix + json)
    fflush(stdout)
}

private func run() async -> Int32 {
    guard CommandLine.arguments.count >= 2 else {
        emit("error", ErrorPayload(message: "缺少请求 JSON 文件路径。"))
        return 2
    }

    do {
        let requestURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: requestURL)
        let request = try JSONDecoder().decode(BackendRequest.self, from: data)

        let generator = SubtitleGenerator()
        let segments = try await generator.generateDiarizedSubtitles(
            preparedAudio16kURL: URL(fileURLWithPath: request.preparedAudio16kPath),
            preparedAudio48kURL: request.preparedAudio48kPath.map { URL(fileURLWithPath: $0) },
            whisperModelURL: URL(fileURLWithPath: request.whisperModelPath),
            alignerModelURL: URL(fileURLWithPath: request.alignerModelPath),
            vadModelURL: URL(fileURLWithPath: request.vadModelPath),
            speakerModelURL: URL(fileURLWithPath: request.speakerModelPath),
            whisperBaseDir: URL(fileURLWithPath: request.whisperBaseDir),
            alignerBaseDir: URL(fileURLWithPath: request.alignerBaseDir),
            speakerBaseDir: URL(fileURLWithPath: request.speakerBaseDir),
            alignerModelId: request.alignerModelId,
            modelStorageRoot: request.modelStorageRoot.map { URL(fileURLWithPath: $0) },
            expectedSpeakers: request.expectedSpeakers,
            language: request.language,
            enableDiarization: request.enableDiarization,
            prefixSpeakerName: request.prefixSpeakerName,
            enableAlignment: request.enableAlignment,
            vocalPreprocessing: request.vocalPreprocessing,
            referenceText: request.referenceText,
            progressCallback: { step, progress, message in
                emit("progress", ProgressPayload(step: step, progress: progress, message: message))
            }
        )

        emit("result", ResultPayload(segments: segments.map {
            SegmentPayload(text: $0.text, startTime: $0.startTime, endTime: $0.endTime)
        }))
        return 0
    } catch {
        emit("error", ErrorPayload(message: error.localizedDescription))
        return 1
    }
}

exit(await run())
