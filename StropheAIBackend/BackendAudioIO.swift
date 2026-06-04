//
//  BackendAudioIO.swift
//  StropheAIBackend
//
//  Created by Codex on 2026/06/04.
//

import AVFoundation
import Foundation

nonisolated enum BackendAudioIO {
    struct AudioBuffer {
        let samples: [Float]
        let sampleRate: Int
    }

    static func readMonoFloatWav(_ url: URL) throws -> AudioBuffer {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(
                domain: "BackendAudioIO",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 WAV 读取缓冲。"]
            )
        }

        try file.read(into: buffer)

        guard let channels = buffer.floatChannelData else {
            throw NSError(
                domain: "BackendAudioIO",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "WAV 不是可读取的 Float PCM 音频。"]
            )
        }

        let channelCount = Int(format.channelCount)
        let sampleCount = Int(buffer.frameLength)
        guard channelCount > 0, sampleCount > 0 else {
            throw NSError(
                domain: "BackendAudioIO",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "WAV 音频为空。"]
            )
        }

        if channelCount == 1 {
            return AudioBuffer(
                samples: Array(UnsafeBufferPointer(start: channels[0], count: sampleCount)),
                sampleRate: Int(format.sampleRate.rounded())
            )
        }

        var mono = [Float](repeating: 0, count: sampleCount)
        for channelIndex in 0..<channelCount {
            let channel = channels[channelIndex]
            for sampleIndex in 0..<sampleCount {
                mono[sampleIndex] += channel[sampleIndex] / Float(channelCount)
            }
        }

        return AudioBuffer(samples: mono, sampleRate: Int(format.sampleRate.rounded()))
    }

    static func writeMonoWav(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard !samples.isEmpty else {
            throw NSError(
                domain: "BackendAudioIO",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "无法写入空音频到 WAV。"]
            )
        }

        try? FileManager.default.removeItem(at: url)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "BackendAudioIO",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 WAV 输出音频格式。"]
            )
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw NSError(
                domain: "BackendAudioIO",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 WAV 输出音频缓冲。"]
            )
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else {
            throw NSError(
                domain: "BackendAudioIO",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "无法访问 WAV 输出音频缓冲。"]
            )
        }

        samples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                channel.update(from: baseAddress, count: samples.count)
            }
        }

        let outputFile = try AVAudioFile(forWriting: url, settings: format.settings)
        try outputFile.write(from: buffer)
    }
}
