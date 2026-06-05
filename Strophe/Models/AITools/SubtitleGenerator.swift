//
//  SubtitleGenerator.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/28.
//

import Foundation
import Darwin       // for statfs
import MLX
import Qwen3ASR
import SpeechEnhancement
import SpeechVAD
import AudioCommon
import Spleeter

private nonisolated struct TimeRange: Sendable {
    let start: Double
    let end: Double

    var duration: Double { max(0, end - start) }
}

// MARK: - SubtitleGenerator

/// 使用 Actor 隔离，防止大规模 AI 运算和对齐操作阻塞主线程
actor SubtitleGenerator {

    // MARK: - Non-isolated Helper Methods (Swift 6 Safe)

    /// 使用 POSIX statfs 检测指定路径所在卷的文件系统类型名称
    nonisolated private func volumeFilesystemType(at url: URL) -> String {
        var buf = statfs()
        guard url.path.withCString({ statfs($0, &buf) }) == 0 else { return "unknown" }
        // f_fstypename 是固定长度的 C 字符数组，需要逐字节转换
        return withUnsafeBytes(of: buf.f_fstypename) { ptr in
            String(bytes: ptr.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "unknown"
        }
    }

    /// 如果卷格式为 APFS 或 HFS+（macOS 原生格式），CoreML 可以直接 mmap，无需复制
    nonisolated private func volumeSupportsDirectMmap(at url: URL) -> Bool {
        let fsType = volumeFilesystemType(at: url)
        return fsType == "apfs" || fsType == "hfs"
    }

    /// 极速高精度线性重采样器，将 48kHz PCM 重采样为 16kHz PCM
    nonisolated private func resample(_ samples: [Float], from srcRate: Int, to dstRate: Int) -> [Float] {
        guard srcRate != dstRate else { return samples }
        let ratio = Float(srcRate) / Float(dstRate)
        let newLength = Int(Float(samples.count) / ratio)
        var result = [Float](repeating: 0, count: newLength)
        for i in 0..<newLength {
            let srcIndex = Float(i) * ratio
            let index = Int(srcIndex)
            let fraction = srcIndex - Float(index)
            if index + 1 < samples.count {
                result[i] = samples[index] * (1.0 - fraction) + samples[index + 1] * fraction
            } else if index < samples.count {
                result[i] = samples[index]
            }
        }
        return result
    }

    /// DeepFilterNet3 CoreML 输入的时间维上限是 6000 帧。48kHz、hop=480 时约为 60 秒；
    /// 这里用 45 秒块并做 1 秒交叉淡化，避免长音频一次性推理触发 CoreML shape 错误。
    private func enhanceLongAudioWithDeepFilterNet3(
        _ denoiser: SpeechEnhancer,
        samples: [Float],
        sampleRate: Int,
        progressCallback: (@Sendable (Int, Double, String) -> Void)?
    ) throws -> [Float] {
        guard !samples.isEmpty else { return [] }

        let chunkSampleCount = sampleRate * 45
        let overlapSampleCount = sampleRate
        guard samples.count > chunkSampleCount else {
            return try denoiser.enhance(audio: samples, sampleRate: sampleRate)
        }

        let stepSampleCount = chunkSampleCount - overlapSampleCount
        let totalChunks = Int(ceil(Double(max(samples.count - overlapSampleCount, 1)) / Double(stepSampleCount)))
        var output: [Float] = []
        output.reserveCapacity(samples.count)

        var chunkIndex = 0
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + chunkSampleCount)
            let chunk = Array(samples[start..<end])
            let enhanced = try denoiser.enhance(audio: chunk, sampleRate: sampleRate)

            if output.isEmpty {
                output.append(contentsOf: enhanced)
            } else {
                let overlap = min(overlapSampleCount, output.count, enhanced.count)
                let fadeStart = output.count - overlap
                if overlap > 0 {
                    for i in 0..<overlap {
                        let fadeIn = Float(i + 1) / Float(overlap + 1)
                        output[fadeStart + i] = output[fadeStart + i] * (1 - fadeIn) + enhanced[i] * fadeIn
                    }
                }
                if enhanced.count > overlap {
                    output.append(contentsOf: enhanced[overlap...])
                }
            }

            chunkIndex += 1
            let fraction = Double(chunkIndex) / Double(max(totalChunks, 1))
            progressCallback?(0, 0.78 + min(fraction, 1) * 0.17, "正在分块过滤环境风噪与人声杂音 (\(chunkIndex)/\(totalChunks))...")

            if end >= samples.count { break }
            start += stepSampleCount
        }

        if output.count > samples.count {
            output.removeLast(output.count - samples.count)
        } else if output.count < samples.count {
            output.append(contentsOf: repeatElement(Float(0), count: samples.count - output.count))
        }
        return output
    }

    /// 将字词级时间戳片段合并为字幕级的块
    /// 普通说话优先按说话人、停顿和标点成句，字符数只作为兜底约束。
    nonisolated private func mergeWordsToSegments(
        words: [AIResultSegment],
        maxGap: Double = 0.9,
        maxDuration: Double = 7.0,
        preferredChars: Int = 18,
        maxChars: Int = 26,
        includeSpeakerLabel: Bool = false
    ) -> [AIResultSegment] {
        guard !words.isEmpty else { return [] }

        /// 从字幕 text 中提取说话人前缀标签（例如 "[Speaker 0]"），用于判断同一说话人
        func speakerLabel(in text: String) -> String {
            if text.hasPrefix("["), let end = text.firstIndex(of: "]") {
                return String(text[text.startIndex...end])
            }
            return "_no_speaker_"
        }

        func stripSpeakerLabel(_ text: String) -> String {
            if text.hasPrefix("["), let end = text.firstIndex(of: "]") {
                let startIndex = text.index(after: end)
                return text[startIndex...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return text
        }

        func subtitleText(_ text: String, speaker: String) -> String {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return "" }
            return includeSpeakerLabel && speaker != "_no_speaker_" ? "\(speaker) \(cleaned)" : cleaned
        }

        func appendToken(_ token: String, to text: String) -> String {
            guard !text.isEmpty else { return token }
            guard let first = token.first else { return text }
            let noSpaceBefore = "，。！？；、：,.!?;:)）】」』".contains(first)
            let needsSpace = !noSpaceBefore && first.isASCII
            return text + (needsSpace ? " " : "") + token
        }

        func endsWithStrongBoundary(_ text: String) -> Bool {
            guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
            return "。！？；.!?;".contains(last)
        }

        func endsWithWeakBoundary(_ text: String) -> Bool {
            guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
            return "，、：,:".contains(last)
        }

        func visibleLength(_ text: String) -> Int {
            countAlignableCharacters(in: stripSpeakerLabel(text))
        }

        var result: [AIResultSegment] = []
        var bufText    = stripSpeakerLabel(words[0].text)
        var bufStart   = words[0].startTime
        var bufEnd     = words[0].endTime
        var bufSpeaker = speakerLabel(in: words[0].text)

        for w in words.dropFirst() {
            let gap = w.startTime - bufEnd
            let dur = w.endTime - bufStart
            let curSpkr = speakerLabel(in: w.text)
            let sameSpkr = curSpkr == bufSpeaker

            let curText = stripSpeakerLabel(w.text)
            let combinedText = appendToken(curText, to: bufText)
            let combinedLen = visibleLength(combinedText)
            let bufLen = visibleLength(bufText)

            let shouldFlush =
                !sameSpkr ||
                gap > maxGap ||
                dur > maxDuration ||
                endsWithStrongBoundary(bufText) ||
                (endsWithWeakBoundary(bufText) && bufLen >= preferredChars) ||
                combinedLen > maxChars

            if shouldFlush {
                let text = subtitleText(bufText, speaker: bufSpeaker)
                if !text.isEmpty {
                    result.append(AIResultSegment(text: text, startTime: bufStart, endTime: bufEnd))
                }
                bufText = curText
                bufStart = w.startTime
                bufEnd = w.endTime
                bufSpeaker = curSpkr
            } else {
                bufText = combinedText
                bufEnd = w.endTime
            }
        }

        let text = subtitleText(bufText, speaker: bufSpeaker)
        if !text.isEmpty {
            result.append(AIResultSegment(text: text, startTime: bufStart, endTime: bufEnd))
        }

        return result
    }

    nonisolated private func transcriptTextForAlignment(from segments: [AIResultSegment]) -> String {
        formatTranscriptForAlignment(segments.map(\.text).joined(separator: " "))
    }

    nonisolated private func formatTranscriptForAlignment(_ text: String) -> String {
        let strongBoundaries = CharacterSet(charactersIn: "。！？；.!?;")
        let weakBoundaries = CharacterSet(charactersIn: "，、：,:")
        var result = ""
        var lastWasWhitespace = false

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasWhitespace {
                    result.append(" ")
                    lastWasWhitespace = true
                }
                continue
            }

            result.unicodeScalars.append(scalar)
            if strongBoundaries.contains(scalar) {
                result.append("\n")
                lastWasWhitespace = true
            } else if weakBoundaries.contains(scalar) {
                result.append(" ")
                lastWasWhitespace = true
            } else {
                lastWasWhitespace = false
            }
        }

        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        while result.contains(" \n") {
            result = result.replacingOccurrences(of: " \n", with: "\n")
        }
        while result.contains("\n ") {
            result = result.replacingOccurrences(of: "\n ", with: "\n")
        }
        while result.contains("\n\n") {
            result = result.replacingOccurrences(of: "\n\n", with: "\n")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Qwen3-ASR only returns text. When alignment is disabled, create coarse subtitle
    /// chunks by distributing text across the audio duration.
    nonisolated private func makeCoarseSegments(
        text: String,
        duration: Double,
        offset: Double = 0,
        maxChars: Int = 18
    ) -> [AIResultSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, duration > 0 else { return [] }

        var chunks: [String] = []
        var current = ""
        let breakChars = CharacterSet(charactersIn: "，。！？；、,.!?; \n")

        for scalar in trimmed.unicodeScalars {
            current.unicodeScalars.append(scalar)
            let shouldBreak = breakChars.contains(scalar) || current.count >= maxChars
            if shouldBreak {
                let chunk = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !chunk.isEmpty { chunks.append(chunk) }
                current = ""
            }
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        if chunks.isEmpty { chunks = [trimmed] }

        let totalChars = max(1, chunks.reduce(0) { $0 + max(1, $1.count) })
        var cursor = 0.0
        return chunks.enumerated().map { index, chunk in
            let proportion = Double(max(1, chunk.count)) / Double(totalChars)
            let segmentDuration = index == chunks.indices.last ? duration - cursor : max(0.8, duration * proportion)
            let start = cursor
            let end = min(duration, start + segmentDuration)
            cursor = end
            return AIResultSegment(
                text: chunk,
                startTime: offset + start,
                endTime: offset + max(end, start + 0.2)
            )
        }
    }

    nonisolated private func transcribeInChunks(
        model: Qwen3ASRModel,
        coremlEncoder: CoreMLASREncoder?,
        samples: [Float],
        sampleRate: Int,
        language: String?,
        maxChunkDuration: Double = 12.0,
        maxTokens: Int = 448,
        progressCallback: (@Sendable (Int, Double, String) -> Void)?
    ) throws -> [AIResultSegment] {
        let chunkSize = max(1, Int(maxChunkDuration * Double(sampleRate)))
        let totalChunks = max(1, Int(ceil(Double(samples.count) / Double(chunkSize))))
        var segments: [AIResultSegment] = []

        for chunkIndex in 0..<totalChunks {
            try autoreleasepool {
                let startSample = chunkIndex * chunkSize
                let endSample = min(startSample + chunkSize, samples.count)
                guard startSample < endSample else { return }

                let chunk = Array(samples[startSample..<endSample])
                let startTime = Double(startSample) / Double(sampleRate)
                let duration = Double(chunk.count) / Double(sampleRate)
                progressCallback?(
                    1,
                    0.25 + (Double(chunkIndex) / Double(totalChunks)) * 0.70,
                    "正在分块运行 Qwen3-ASR (\(chunkIndex + 1)/\(totalChunks))..."
                )

                let text: String
                if let coremlEncoder {
                    text = try model.transcribe(
                        audio: chunk,
                        sampleRate: sampleRate,
                        language: language,
                        maxTokens: maxTokens,
                        coremlEncoder: coremlEncoder
                    )
                } else {
                    text = model.transcribe(
                        audio: chunk,
                        sampleRate: sampleRate,
                        options: Qwen3DecodingOptions(
                            maxTokens: maxTokens,
                            language: language
                        )
                    )
                }
                segments.append(contentsOf: makeCoarseSegments(
                    text: text,
                    duration: duration,
                    offset: startTime
                ))
            }
            Memory.clearCache()
        }

        return segments
    }

    nonisolated private func transcribeSpeechIslands(
        model: Qwen3ASRModel,
        coremlEncoder: CoreMLASREncoder?,
        samples: [Float],
        sampleRate: Int,
        language: String?,
        speechRanges: [TimeRange],
        maxChunkDuration: Double = 12.0,
        maxTokens: Int = 448,
        progressCallback: (@Sendable (Int, Double, String) -> Void)?
    ) throws -> [AIResultSegment] {
        guard !speechRanges.isEmpty else {
            return try transcribeInChunks(
                model: model,
                coremlEncoder: coremlEncoder,
                samples: samples,
                sampleRate: sampleRate,
                language: language,
                maxChunkDuration: maxChunkDuration,
                maxTokens: maxTokens,
                progressCallback: progressCallback
            )
        }

        let chunkSize = max(1, Int(maxChunkDuration * Double(sampleRate)))
        let plannedChunks = speechRanges.reduce(0) { total, range in
            let startSample = max(0, min(samples.count, Int(range.start * Double(sampleRate))))
            let endSample = max(startSample, min(samples.count, Int(range.end * Double(sampleRate))))
            guard startSample < endSample else { return total }
            return total + max(1, Int(ceil(Double(endSample - startSample) / Double(chunkSize))))
        }

        let totalChunks = max(1, plannedChunks)
        var chunkIndex = 0
        var segments: [AIResultSegment] = []

        for (islandIndex, range) in speechRanges.enumerated() {
            let islandStartSample = max(0, min(samples.count, Int(range.start * Double(sampleRate))))
            let islandEndSample = max(islandStartSample, min(samples.count, Int(range.end * Double(sampleRate))))
            guard islandStartSample < islandEndSample else { continue }

            var startSample = islandStartSample
            while startSample < islandEndSample {
                try autoreleasepool {
                    let endSample = min(startSample + chunkSize, islandEndSample)
                    guard startSample < endSample else { return }

                    let chunk = Array(samples[startSample..<endSample])
                    let startTime = Double(startSample) / Double(sampleRate)
                    let duration = Double(chunk.count) / Double(sampleRate)
                    progressCallback?(
                        1,
                        0.25 + (Double(chunkIndex) / Double(totalChunks)) * 0.70,
                        "正在按语音岛运行 Qwen3-ASR (\(islandIndex + 1)/\(speechRanges.count), \(chunkIndex + 1)/\(totalChunks))..."
                    )

                    let text: String
                    if let coremlEncoder {
                        text = try model.transcribe(
                            audio: chunk,
                            sampleRate: sampleRate,
                            language: language,
                            maxTokens: maxTokens,
                            coremlEncoder: coremlEncoder
                        )
                    } else {
                        text = model.transcribe(
                            audio: chunk,
                            sampleRate: sampleRate,
                            options: Qwen3DecodingOptions(
                                maxTokens: maxTokens,
                                language: language
                            )
                        )
                    }
                    segments.append(contentsOf: makeCoarseSegments(
                        text: text,
                        duration: duration,
                        offset: startTime
                    ))
                }
                chunkIndex += 1
                startSample += chunkSize
                Memory.clearCache()
            }
        }

        return segments
    }

    nonisolated private func transcribeWithIsolatedASRModel(
        cacheDir: URL,
        coremlEncoderCacheDir: URL?,
        samples: [Float],
        sampleRate: Int,
        language: String?,
        speechRanges: [TimeRange],
        maxChunkDuration: Double,
        maxTokens: Int,
        progressCallback: (@Sendable (Int, Double, String) -> Void)?
    ) async throws -> [AIResultSegment] {
        let asrModel = try await Qwen3ASRModel.fromPretrained(
            cacheDir: cacheDir,
            offlineMode: true
        )
        let coremlEncoder: CoreMLASREncoder?
        if let coremlEncoderCacheDir {
            coremlEncoder = try await CoreMLASREncoder.fromPretrained(
                cacheDir: coremlEncoderCacheDir,
                offlineMode: true
            )
            try coremlEncoder?.warmUp()
        } else {
            coremlEncoder = nil
        }
        let segments = try transcribeSpeechIslands(
            model: asrModel,
            coremlEncoder: coremlEncoder,
            samples: samples,
            sampleRate: sampleRate,
            language: language,
            speechRanges: speechRanges,
            maxChunkDuration: maxChunkDuration,
            maxTokens: maxTokens,
            progressCallback: progressCallback
        )
        Memory.clearCache()
        return segments
    }

    nonisolated private var asrChunkDuration: Double {
        #if os(iOS)
        return 4.0
        #else
        return 12.0
        #endif
    }

    nonisolated private var asrMaxTokensPerChunk: Int {
        #if os(iOS)
        return 192
        #else
        return 448
        #endif
    }

    nonisolated private func normalizedReferenceLines(from text: String?) -> [String] {
        guard let text else { return [] }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated private func clampOverlapsToNextStart(_ segments: [AIResultSegment]) -> [AIResultSegment] {
        guard segments.count > 1 else { return segments }

        var result = segments.sorted {
            if $0.startTime == $1.startTime {
                return $0.endTime < $1.endTime
            }
            return $0.startTime < $1.startTime
        }

        for index in 0..<(result.count - 1) {
            let current = result[index]
            let nextStart = result[index + 1].startTime
            guard current.endTime > nextStart else { continue }

            result[index] = AIResultSegment(
                text: current.text,
                startTime: current.startTime,
                endTime: max(current.startTime, nextStart)
            )
        }

        return result
    }

    nonisolated private func countAlignableCharacters(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) ? count : count + 1
        }
    }

    nonisolated private func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = min(1, max(0, p))
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * clamped))
        return sorted[index]
    }

    nonisolated private func rmsEnvelope(
        samples: [Float],
        sampleRate: Int,
        frameDuration: Double = 0.025
    ) -> [(time: Double, rms: Float)] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }

        let frameSize = max(1, Int(frameDuration * Double(sampleRate)))
        var envelope: [(time: Double, rms: Float)] = []
        var index = 0

        while index < samples.count {
            let end = min(index + frameSize, samples.count)
            var sum: Float = 0
            for sample in samples[index..<end] {
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(max(1, end - index)))
            let centerTime = (Double(index) + Double(end - index) * 0.5) / Double(sampleRate)
            envelope.append((time: centerTime, rms: rms))
            index += frameSize
        }

        return envelope
    }

    nonisolated private func vocalEnergyThreshold(
        envelope: [(time: Double, rms: Float)]
    ) -> Float {
        let values = envelope.map { $0.rms }
        guard !values.isEmpty else { return 0.0006 }
        let floor = percentile(values, 0.25)
        let strong = percentile(values, 0.90)
        return max(floor * 2.2, strong * 0.10, 0.0006)
    }

    nonisolated private func nearestFrameIndex(
        in envelope: [(time: Double, rms: Float)],
        to time: Double
    ) -> Int? {
        guard !envelope.isEmpty else { return nil }
        var bestIndex = 0
        var bestDistance = abs(envelope[0].time - time)
        for index in envelope.indices.dropFirst() {
            let distance = abs(envelope[index].time - time)
            if distance < bestDistance {
                bestIndex = index
                bestDistance = distance
            }
        }
        return bestIndex
    }

    nonisolated private func snapStartToVocalEnergy(
        original: Double,
        minTime: Double,
        maxTime: Double,
        envelope: [(time: Double, rms: Float)],
        threshold: Float
    ) -> Double {
        guard minTime < maxTime else { return original }

        let indices = envelope.indices.filter { envelope[$0].time >= minTime && envelope[$0].time <= maxTime }
        guard !indices.isEmpty else { return min(max(original, minTime), maxTime) }

        var bestCrossing: (time: Double, distance: Double)?
        for index in indices {
            let current = envelope[index]
            guard current.rms >= threshold else { continue }
            let previousRMS = index > 0 ? envelope[index - 1].rms : 0
            let nextRMS = index + 1 < envelope.count ? envelope[index + 1].rms : current.rms
            let isSustained = nextRMS >= threshold * 0.80
            let isRisingEdge = previousRMS < threshold * 0.75
            guard isSustained && isRisingEdge else { continue }

            let distance = abs(current.time - original)
            if bestCrossing == nil || distance < bestCrossing!.distance {
                bestCrossing = (current.time, distance)
            }
        }

        if let bestCrossing {
            return min(max(bestCrossing.time - 0.035, minTime), maxTime)
        }

        if let nearest = nearestFrameIndex(in: envelope, to: original),
           envelope[nearest].rms >= threshold {
            return min(max(original, minTime), maxTime)
        }

        if let firstActive = indices.first(where: { envelope[$0].rms >= threshold }) {
            return min(max(envelope[firstActive].time - 0.035, minTime), maxTime)
        }

        if let peak = indices.max(by: { envelope[$0].rms < envelope[$1].rms }) {
            return min(max(envelope[peak].time - 0.08, minTime), maxTime)
        }

        return min(max(original, minTime), maxTime)
    }

    nonisolated private func snapEndToVocalEnergy(
        original: Double,
        minTime: Double,
        maxTime: Double,
        envelope: [(time: Double, rms: Float)],
        threshold: Float
    ) -> Double {
        guard minTime < maxTime else { return original }

        let indices = envelope.indices.filter { envelope[$0].time >= minTime && envelope[$0].time <= maxTime }
        guard !indices.isEmpty else { return min(max(original, minTime), maxTime) }

        var bestDrop: (time: Double, distance: Double)?
        for index in indices {
            let current = envelope[index]
            let previousRMS = index > 0 ? envelope[index - 1].rms : current.rms
            let isFallingEdge = previousRMS >= threshold && current.rms < threshold * 0.80
            guard isFallingEdge else { continue }

            let distance = abs(current.time - original)
            if bestDrop == nil || distance < bestDrop!.distance {
                bestDrop = (current.time, distance)
            }
        }

        if let bestDrop {
            return min(max(bestDrop.time + 0.035, minTime), maxTime)
        }

        if let lastActive = indices.last(where: { envelope[$0].rms >= threshold }) {
            return min(max(envelope[lastActive].time + 0.06, minTime), maxTime)
        }

        if let peak = indices.max(by: { envelope[$0].rms < envelope[$1].rms }) {
            return min(max(envelope[peak].time + 0.12, minTime), maxTime)
        }

        return min(max(original, minTime), maxTime)
    }

    nonisolated private func snapSegmentsToVocalEnergy(
        _ segments: [AIResultSegment],
        samples: [Float],
        sampleRate: Int
    ) -> [AIResultSegment] {
        guard !segments.isEmpty, !samples.isEmpty, sampleRate > 0 else { return segments }

        let audioDuration = Double(samples.count) / Double(sampleRate)
        let envelope = rmsEnvelope(samples: samples, sampleRate: sampleRate)
        guard !envelope.isEmpty else { return segments }

        let threshold = vocalEnergyThreshold(envelope: envelope)
        var snapped: [AIResultSegment] = []
        var previousEnd = 0.0

        for index in segments.indices {
            let segment = segments[index]
            let nextStart = index + 1 < segments.count ? segments[index + 1].startTime : audioDuration
            let bounds = lyricLineDurationBounds(for: segment.text)

            let startFloor = snapped.isEmpty ? 0.0 : previousEnd + 0.03
            let startMin = max(startFloor, segment.startTime - 0.55)
            let startMax = min(
                min(segment.startTime + 0.45, segment.endTime - 0.20),
                max(startMin, nextStart - 0.12)
            )
            var start = snapStartToVocalEnergy(
                original: segment.startTime,
                minTime: startMin,
                maxTime: max(startMin, startMax),
                envelope: envelope,
                threshold: threshold
            )

            let endMin = max(start + 0.25, segment.endTime - 0.50)
            let endMax = min(
                min(audioDuration, nextStart - 0.03),
                min(segment.endTime + 0.70, start + bounds.max)
            )
            var end = snapEndToVocalEnergy(
                original: segment.endTime,
                minTime: min(endMin, endMax),
                maxTime: max(endMin, endMax),
                envelope: envelope,
                threshold: threshold
            )

            if end - start < bounds.min * 0.55 {
                end = min(max(end, start + bounds.min * 0.55), max(endMax, endMin))
            }
            if end <= start {
                end = min(audioDuration, start + 0.35)
            }

            start = max(start, startFloor)
            end = min(max(end, start + 0.25), audioDuration)

            snapped.append(AIResultSegment(
                text: segment.text,
                startTime: start,
                endTime: end
            ))
            previousEnd = end
        }

        return snapped
    }

    nonisolated private func detectActiveRanges(
        samples: [Float],
        sampleRate: Int,
        frameDuration: Double = 0.05,
        minActiveDuration: Double = 0.25,
        mergeGap: Double = 2.2,
        padding: Double = 0.25
    ) -> [TimeRange] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }

        let frameSize = max(1, Int(frameDuration * Double(sampleRate)))
        var rmsValues: [Float] = []
        var frameStarts: [Double] = []

        var index = 0
        while index < samples.count {
            let end = min(index + frameSize, samples.count)
            var sum: Float = 0
            for sample in samples[index..<end] {
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(max(1, end - index)))
            rmsValues.append(rms)
            frameStarts.append(Double(index) / Double(sampleRate))
            index += frameSize
        }

        let floor = percentile(rmsValues, 0.25)
        let strong = percentile(rmsValues, 0.92)
        let threshold = max(floor * 2.0, strong * 0.06, 0.0006)

        var ranges: [TimeRange] = []
        var activeStart: Double?
        for (idx, rms) in rmsValues.enumerated() {
            let isActive = rms >= threshold
            let start = frameStarts[idx]
            let end = min(Double(samples.count) / Double(sampleRate), start + frameDuration)

            if isActive, activeStart == nil {
                activeStart = start
            } else if !isActive, let startTime = activeStart {
                if end - startTime >= minActiveDuration {
                    ranges.append(TimeRange(
                        start: max(0, startTime - padding),
                        end: min(Double(samples.count) / Double(sampleRate), start + padding)
                    ))
                }
                activeStart = nil
            }

            if idx == rmsValues.indices.last, let startTime = activeStart {
                if end - startTime >= minActiveDuration {
                    ranges.append(TimeRange(
                        start: max(0, startTime - padding),
                        end: min(Double(samples.count) / Double(sampleRate), end + padding)
                    ))
                }
            }
        }

        guard !ranges.isEmpty else { return [] }

        var merged: [TimeRange] = []
        for range in ranges {
            if let last = merged.last, range.start - last.end <= mergeGap {
                merged[merged.count - 1] = TimeRange(start: last.start, end: max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    nonisolated private func mergeSpeechRanges(
        _ ranges: [TimeRange],
        audioDuration: Double,
        padding: Double = 0.18,
        mergeGap: Double = 0.45,
        minDuration: Double = 0.20
    ) -> [TimeRange] {
        let padded = ranges
            .map {
                TimeRange(
                    start: max(0, $0.start - padding),
                    end: min(audioDuration, $0.end + padding)
                )
            }
            .filter { $0.duration >= minDuration }
            .sorted { $0.start < $1.start }

        guard !padded.isEmpty else { return [] }

        var merged: [TimeRange] = []
        for range in padded {
            if let last = merged.last, range.start - last.end <= mergeGap {
                merged[merged.count - 1] = TimeRange(start: last.start, end: max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func detectSpeechIslands(
        samples: [Float],
        sampleRate: Int,
        vadModelURL: URL,
        progressCallback: (@Sendable (Int, Double, String) -> Void)?
    ) async throws -> [TimeRange] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }

        progressCallback?(1, 0.05, "正在加载 Pyannote VAD 语音活动检测模型...")
        let audioDuration = Double(samples.count) / Double(sampleRate)
        let vadConfig = pyannoteVADConfig(audioDuration: audioDuration)
        let vad = try await PyannoteVADModel.fromPretrained(
            modelId: "aufklarer/Pyannote-Segmentation-MLX",
            vadConfig: vadConfig,
            cacheDir: vadModelURL,
            offlineMode: true
        )

        let estimatedWindowCount = pyannoteWindowCount(
            sampleCount: samples.count,
            sampleRate: sampleRate,
            vadConfig: vadConfig
        )
        progressCallback?(1, 0.12, "正在快速检测语音活动区间 (\(estimatedWindowCount) 个窗口)...")
        print("🎙️ Pyannote VAD fast config: stepRatio=\(vadConfig.stepRatio), windows=\(estimatedWindowCount), duration=\(String(format: "%.1f", audioDuration))s")
        let detected = vad.detectSpeech(audio: samples, sampleRate: sampleRate).map {
            TimeRange(start: Double($0.startTime), end: Double($0.endTime))
        }
        let speechRanges = mergeSpeechRanges(detected, audioDuration: audioDuration)
        vad.unload()
        Memory.clearCache()

        return speechRanges.isEmpty
            ? [TimeRange(start: 0, end: audioDuration)]
            : speechRanges
    }

    nonisolated private func pyannoteVADConfig(audioDuration: Double) -> VADConfig {
        let stepRatio: Float
        #if os(iOS)
        stepRatio = audioDuration > 900 ? 0.75 : 0.50
        #else
        stepRatio = audioDuration > 900 ? 0.75 : (audioDuration > 60 ? 0.50 : 0.25)
        #endif

        return VADConfig(
            onset: 0.767,
            offset: 0.377,
            minSpeechDuration: 0.136,
            minSilenceDuration: 0.067,
            windowDuration: 10.0,
            stepRatio: stepRatio
        )
    }

    nonisolated private func pyannoteWindowCount(
        sampleCount: Int,
        sampleRate: Int,
        vadConfig: VADConfig
    ) -> Int {
        guard sampleCount > 0, sampleRate > 0 else { return 0 }
        let windowSamples = Int(vadConfig.windowDuration * Float(sampleRate))
        let stepSamples = max(1, Int(vadConfig.windowDuration * vadConfig.stepRatio * Float(sampleRate)))

        if sampleCount <= windowSamples {
            return 1
        }

        var count = 0
        var start = 0
        while start + windowSamples <= sampleCount {
            count += 1
            start += stepSamples
        }
        if count == 0 || (start - stepSamples + windowSamples) < sampleCount {
            count += 1
        }
        return count
    }

    nonisolated private func lyricLineDurationBounds(for text: String) -> (min: Double, max: Double) {
        let charCount = max(1, countAlignableCharacters(in: text))
        let minDuration = min(2.4, max(1.45, Double(charCount) * 0.18))
        let maxDuration = min(8.0, max(2.4, Double(charCount) * 0.42 + 1.0))
        return (minDuration, maxDuration)
    }

    nonisolated private func timeAtActiveProgress(_ progress: Double, activeRanges: [TimeRange], fallbackDuration: Double) -> Double {
        let clamped = min(1, max(0, progress))
        guard !activeRanges.isEmpty else {
            return fallbackDuration * clamped
        }

        let totalActiveDuration = activeRanges.reduce(0) { $0 + $1.duration }
        guard totalActiveDuration > 0 else {
            return fallbackDuration * clamped
        }

        var remaining = totalActiveDuration * clamped
        for range in activeRanges {
            if remaining <= range.duration {
                return range.start + remaining
            }
            remaining -= range.duration
        }
        return activeRanges.last?.end ?? fallbackDuration
    }

    nonisolated private func activeRangeIntersecting(
        start: Double,
        end: Double,
        activeRanges: [TimeRange]
    ) -> TimeRange? {
        var best: (range: TimeRange, overlap: Double)?
        for range in activeRanges {
            let overlap = min(end, range.end) - max(start, range.start)
            guard overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap {
                best = (range, overlap)
            }
        }
        return best?.range
    }

    nonisolated private func clampLyricLineTiming(
        start: Double,
        end: Double,
        text: String,
        searchWindow: TimeRange,
        activeRanges: [TimeRange],
        previousEnd: Double
    ) -> TimeRange {
        let charCount = max(1, countAlignableCharacters(in: text))
        let maxDuration = min(9.0, max(2.2, Double(charCount) * 0.42 + 1.2))
        var lineStart = max(searchWindow.start, start)
        var lineEnd = min(searchWindow.end, max(end, start + 0.25))

        if let active = activeRangeIntersecting(
            start: lineStart - 1.0,
            end: lineEnd + 1.0,
            activeRanges: activeRanges
        ) {
            lineStart = max(lineStart, active.start)
            lineEnd = min(max(lineEnd, lineStart + 0.25), active.end)
        }

        if lineEnd - lineStart > maxDuration {
            let endAnchoredStart = max(lineStart, lineEnd - maxDuration)
            lineStart = max(endAnchoredStart, previousEnd + 0.04)
        }

        lineStart = max(lineStart, previousEnd + 0.04)
        if lineEnd <= lineStart {
            lineEnd = min(searchWindow.end, lineStart + min(maxDuration, 2.0))
        }

        return TimeRange(start: lineStart, end: max(lineEnd, lineStart + 0.25))
    }

    nonisolated private func makeEstimatedLyricWindows(
        referenceLines: [String],
        activeRanges: [TimeRange],
        audioDuration: Double
    ) -> [TimeRange] {
        guard !referenceLines.isEmpty else { return [] }
        let weights = referenceLines.map { max(1, countAlignableCharacters(in: $0)) }
        let totalWeight = max(1, weights.reduce(0, +))
        var cursor = 0

        return referenceLines.indices.map { index in
            let startProgress = Double(cursor) / Double(totalWeight)
            cursor += weights[index]
            let endProgress = Double(cursor) / Double(totalWeight)
            let estimatedStart = timeAtActiveProgress(startProgress, activeRanges: activeRanges, fallbackDuration: audioDuration)
            let estimatedEnd = timeAtActiveProgress(endProgress, activeRanges: activeRanges, fallbackDuration: audioDuration)
            let estimatedDuration = max(1.4, estimatedEnd - estimatedStart)
            let margin = min(7.0, max(2.5, estimatedDuration * 0.9))
            return TimeRange(
                start: max(0, estimatedStart - margin),
                end: min(audioDuration, estimatedEnd + margin)
            )
        }
    }

    nonisolated private func makeLyricSegmentsFromActiveRanges(
        referenceLines: [String],
        samples: [Float],
        sampleRate: Int,
        speechRanges: [TimeRange]
    ) -> [AIResultSegment] {
        guard !referenceLines.isEmpty, !samples.isEmpty, sampleRate > 0 else { return [] }

        let audioDuration = Double(samples.count) / Double(sampleRate)
        let activeRanges = speechRanges.isEmpty ? detectActiveRanges(samples: samples, sampleRate: sampleRate) : speechRanges
        let ranges = activeRanges.isEmpty ? [TimeRange(start: 0, end: audioDuration)] : activeRanges
        let weights = referenceLines.map { max(1, countAlignableCharacters(in: $0)) }
        let totalWeight = max(1, weights.reduce(0, +))

        var cursor = 0
        var rawSegments: [TimeRange] = []
        for index in referenceLines.indices {
            let startProgress = Double(cursor) / Double(totalWeight)
            cursor += weights[index]
            let endProgress = Double(cursor) / Double(totalWeight)
            let start = timeAtActiveProgress(startProgress, activeRanges: ranges, fallbackDuration: audioDuration)
            let end = timeAtActiveProgress(endProgress, activeRanges: ranges, fallbackDuration: audioDuration)
            rawSegments.append(TimeRange(start: start, end: max(end, start + 0.2)))
        }

        var result: [AIResultSegment] = []
        var previousEnd = 0.0

        for (index, line) in referenceLines.enumerated() {
            let raw = rawSegments[index]
            let nextStart = index + 1 < rawSegments.count ? rawSegments[index + 1].start : audioDuration
            let bounds = lyricLineDurationBounds(for: line)

            var start = raw.start
            var end = raw.end

            let gapFromPrevious = start - previousEnd
            if !result.isEmpty, gapFromPrevious >= 0, gapFromPrevious <= 1.6 {
                start = previousEnd + 0.04
            } else {
                start = max(start, previousEnd + 0.04)
            }

            if end - start < bounds.min {
                end = min(max(nextStart - 0.04, start + bounds.min), start + bounds.min)
            }
            if end - start > bounds.max {
                end = start + bounds.max
            }

            if index + 1 < rawSegments.count {
                let maxEndBeforeNext = max(start + 0.25, nextStart - 0.04)
                end = min(end, maxEndBeforeNext)
            }

            if end <= start {
                end = min(audioDuration, start + bounds.min)
            }

            result.append(AIResultSegment(text: line, startTime: start, endTime: end))
            previousEnd = end
        }

        return result
    }

    nonisolated private func lineTimingIsCredible(
        _ candidate: AIResultSegment,
        fallback: AIResultSegment,
        previousEnd: Double,
        audioDuration: Double
    ) -> Bool {
        let duration = candidate.endTime - candidate.startTime
        let bounds = lyricLineDurationBounds(for: candidate.text)

        guard duration >= bounds.min * 0.65, duration <= bounds.max * 1.35 else { return false }
        guard candidate.startTime >= previousEnd - 0.15 else { return false }
        guard candidate.endTime <= audioDuration + 0.2 else { return false }

        let startDelta = abs(candidate.startTime - fallback.startTime)
        let endDelta = abs(candidate.endTime - fallback.endTime)
        let tolerance = max(3.0, min(8.0, fallback.endTime - fallback.startTime + 2.0))
        return startDelta <= tolerance && endDelta <= tolerance
    }

    nonisolated private func smoothLyricSegments(
        _ segments: [AIResultSegment],
        audioDuration: Double
    ) -> [AIResultSegment] {
        guard !segments.isEmpty else { return [] }

        var result: [AIResultSegment] = []
        var previousEnd = 0.0

        for index in segments.indices {
            let segment = segments[index]
            let bounds = lyricLineDurationBounds(for: segment.text)
            let nextStart = index + 1 < segments.count ? segments[index + 1].startTime : audioDuration

            var start = max(segment.startTime, previousEnd + (result.isEmpty ? 0 : 0.04))
            var end = max(segment.endTime, start + bounds.min)

            let gap = start - previousEnd
            if !result.isEmpty, gap > 0, gap <= 1.4 {
                start = previousEnd + 0.04
                end = max(end, start + bounds.min)
            }

            if end - start > bounds.max {
                end = start + bounds.max
            }

            if index + 1 < segments.count, nextStart > start {
                end = min(end, max(start + 0.25, nextStart - 0.04))
            } else {
                end = min(end, audioDuration)
            }

            if end <= start {
                end = min(audioDuration, start + max(0.25, bounds.min))
            }

            result.append(AIResultSegment(text: segment.text, startTime: start, endTime: end))
            previousEnd = end
        }

        return result
    }

    nonisolated private func mergeHybridLyricSegments(
        alignedLineSegments: [AIResultSegment],
        fallbackSegments: [AIResultSegment],
        audioDuration: Double
    ) -> [AIResultSegment] {
        guard !fallbackSegments.isEmpty else { return alignedLineSegments }
        guard alignedLineSegments.count == fallbackSegments.count else { return fallbackSegments }

        var merged: [AIResultSegment] = []
        var previousEnd = 0.0

        for index in fallbackSegments.indices {
            let fallback = fallbackSegments[index]
            let candidate = alignedLineSegments[index]
            let chosen = lineTimingIsCredible(
                candidate,
                fallback: fallback,
                previousEnd: previousEnd,
                audioDuration: audioDuration
            ) ? candidate : fallback

            merged.append(AIResultSegment(
                text: fallback.text,
                startTime: chosen.startTime,
                endTime: chosen.endTime
            ))
            previousEnd = max(previousEnd, chosen.endTime)
        }

        return smoothLyricSegments(merged, audioDuration: audioDuration)
    }

    nonisolated private func mergeAlignedWordsToReferenceLines(
        words: [AIResultSegment],
        referenceLines: [String]
    ) -> [AIResultSegment] {
        guard !words.isEmpty, !referenceLines.isEmpty else { return [] }

        var result: [AIResultSegment] = []
        var wordIndex = 0

        for line in referenceLines {
            let targetCount = max(1, countAlignableCharacters(in: line))
            let lineStartIndex = wordIndex
            var consumedCount = 0

            while wordIndex < words.count && consumedCount < targetCount {
                consumedCount += max(1, countAlignableCharacters(in: words[wordIndex].text))
                wordIndex += 1
            }

            let lineWords = Array(words[lineStartIndex..<wordIndex])
            if let first = lineWords.first, let last = lineWords.last {
                result.append(AIResultSegment(
                    text: line,
                    startTime: first.startTime,
                    endTime: max(last.endTime, first.startTime + 0.2)
                ))
            }
        }

        if wordIndex < words.count, var last = result.popLast() {
            last = AIResultSegment(
                text: last.text,
                startTime: last.startTime,
                endTime: max(words[wordIndex...].map(\.endTime).max() ?? last.endTime, last.endTime)
            )
            result.append(last)
        }

        return result
    }

    nonisolated private func alignReferenceLinesInWindows(
        aligner: Qwen3ForcedAligner?,
        samples: [Float],
        referenceLines: [String],
        sampleRate: Int,
        language: String,
        speechRanges: [TimeRange],
        progressCallback: (@Sendable (Int, Double, String) -> Void)?
    ) -> [AIResultSegment] {
        guard !samples.isEmpty, !referenceLines.isEmpty else { return [] }

        let audioDuration = Double(samples.count) / Double(sampleRate)
        let activeRanges = speechRanges.isEmpty ? detectActiveRanges(samples: samples, sampleRate: sampleRate) : speechRanges
        let estimatedWindows = makeEstimatedLyricWindows(
            referenceLines: referenceLines,
            activeRanges: activeRanges,
            audioDuration: audioDuration
        )

        var results: [AIResultSegment] = []
        var previousEnd = 0.0

        for (index, line) in referenceLines.enumerated() {
            autoreleasepool {
                let estimated = estimatedWindows[index]
                let searchStart = max(0, min(estimated.start, previousEnd + 1.5))
                let searchEnd = min(audioDuration, max(estimated.end, searchStart + 2.0))
                let startSample = max(0, min(samples.count, Int(searchStart * Double(sampleRate))))
                let endSample = max(startSample, min(samples.count, Int(searchEnd * Double(sampleRate))))

                guard startSample < endSample else { return }

                progressCallback?(
                    2,
                    0.35 + (Double(index) / Double(max(1, referenceLines.count))) * 0.6,
                    "正在逐行对齐参考歌词 (\(index + 1)/\(referenceLines.count))..."
                )

                let words = aligner?.align(
                    audio: Array(samples[startSample..<endSample]),
                    text: line,
                    sampleRate: sampleRate,
                    language: language
                ) ?? []

                let rawStart = Double(words.first?.startTime ?? 0) + searchStart
                let rawEnd = Double(words.last?.endTime ?? Float(min(3.0, searchEnd - searchStart))) + searchStart
                let timing = clampLyricLineTiming(
                    start: rawStart,
                    end: rawEnd,
                    text: line,
                    searchWindow: TimeRange(start: searchStart, end: searchEnd),
                    activeRanges: activeRanges,
                    previousEnd: previousEnd
                )

                results.append(AIResultSegment(
                    text: line,
                    startTime: timing.start,
                    endTime: timing.end
                ))
                previousEnd = timing.end
            }
            Memory.clearCache()
        }

        return results
    }

    nonisolated private func alignSegmentsInWindows(
        aligner: Qwen3ForcedAligner,
        samples: [Float],
        segments: [AIResultSegment],
        sampleRate: Int,
        language: String,
        speechRanges: [TimeRange],
        progressCallback: (@Sendable (Int, Double, String) -> Void)?
    ) -> [AIResultSegment] {
        guard !samples.isEmpty, !segments.isEmpty, sampleRate > 0 else { return [] }

        let audioDuration = Double(samples.count) / Double(sampleRate)
        var results: [AIResultSegment] = []

        for (index, segment) in segments.enumerated() {
            autoreleasepool {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }

                let speechRange = activeRangeIntersecting(
                    start: segment.startTime - 0.25,
                    end: segment.endTime + 0.25,
                    activeRanges: speechRanges
                )
                let lowerBound = speechRange?.start ?? 0
                let upperBound = speechRange?.end ?? audioDuration
                let searchStart = max(lowerBound, segment.startTime - 0.15)
                let searchEnd = min(upperBound, max(segment.endTime + 0.25, searchStart + 0.8))
                let startSample = max(0, min(samples.count, Int(searchStart * Double(sampleRate))))
                let endSample = max(startSample, min(samples.count, Int(searchEnd * Double(sampleRate))))
                guard startSample < endSample else { return }

                progressCallback?(
                    2,
                    0.45 + (Double(index) / Double(max(1, segments.count))) * 0.5,
                    "正在低内存逐段对齐字幕 (\(index + 1)/\(segments.count))..."
                )

                let words = aligner.align(
                    audio: Array(samples[startSample..<endSample]),
                    text: text,
                    sampleRate: sampleRate,
                    language: language
                )

                if words.isEmpty {
                    results.append(segment)
                } else {
                    results.append(contentsOf: words.map { word in
                        AIResultSegment(
                            text: word.text,
                            startTime: Double(word.startTime) + searchStart,
                            endTime: Double(word.endTime) + searchStart
                        )
                    })
                }
            }
            Memory.clearCache()
        }

        return results
    }

    nonisolated private func alignInChunks(
        aligner: Qwen3ForcedAligner,
        samples: [Float],
        text: String,
        sampleRate: Int,
        language: String,
        progressCallback: (@Sendable (Int, Double, String) -> Void)?
    ) -> [AIResultSegment] {
        progressCallback?(2, 0.55, "正在运行 ForcedAligner 长音频自动分块对齐...")
        let aligned = aligner.alignLong(
            audio: samples,
            text: text,
            sampleRate: sampleRate,
            language: language,
            progressHandler: { message in
                print("🎯 \(message)")
            }
        )
        Memory.clearCache()
        return aligned.map { word in
            AIResultSegment(
                text: word.text,
                startTime: Double(word.startTime),
                endTime: Double(word.endTime)
            )
        }
    }

    // MARK: - Core Inference Method

    /// 执行智能降噪、语音转写、高精度强制打轴并在启用的情况下分离说话人
    /// - Parameters:
    ///   - preparedAudio16kURL: 主 App 已解码并重采样的 16kHz 单声道 WAV
    ///   - whisperModelURL: 已下载 Whisper 模型的本地路径 URL (现映射为 Qwen3ASR 路径)
    ///   - asrDecoderModelURL: 混合 ASR 时使用的 MLX decoder 模型目录；nil 时使用 whisperModelURL
    ///   - speakerModelURL: 已下载 Speaker 模型的本地路径 URL (现映射为 Pyannote 路径)
    ///   - whisperBaseDir: ASR 模型存储的书签根目录（用于安全域访问）
    ///   - speakerBaseDir: 声纹模型存储的书签根目录（用于安全域访问）
    ///   - modelStorageRoot: 用户授权的模型存储根目录；外置盘必须在这个 URL 上开启安全域访问
    ///   - expectedSpeakers: 期望的说话人数量（若不确定可传 nil）
    ///   - language: 识别语言 ("auto" 或指定语种如 "zh", "zh-TW", "en", etc.)
    ///   - enableDiarization: 是否启用对话人识别
    ///   - prefixSpeakerName: 是否在字幕行中添加发言人前缀
    ///   - progressCallback: 进度回调 (step, stepProgress, statusMessage)
    func generateDiarizedSubtitles(
        preparedAudio16kURL: URL,
        preparedAudio48kURL: URL?,
        whisperModelURL: URL,
        asrDecoderModelURL: URL? = nil,
        alignerModelURL: URL,
        vadModelURL: URL,
        speakerModelURL: URL,
        whisperBaseDir: URL,
        alignerBaseDir: URL,
        speakerBaseDir: URL,
        alignerModelId: String = "aufklarer/Qwen3-ForcedAligner-0.6B-4bit",
        modelStorageRoot: URL? = nil,
        expectedSpeakers: Int? = nil,
        language: String = "auto",
        enableDiarization: Bool = true,
        prefixSpeakerName: Bool = false,
        enableAlignment: Bool = true,
        vocalPreprocessing: String = "denoise",
        referenceText: String? = nil,
        progressCallback: (@Sendable (Int, Double, String) -> Void)? = nil
    ) async throws -> [AIResultSegment] {

        let resolvedWhisperURL = whisperModelURL.resolvingSymlinksInPath()
        let resolvedASRDecoderURL = (asrDecoderModelURL ?? whisperModelURL).resolvingSymlinksInPath()
        let resolvedAlignerURL = alignerModelURL.resolvingSymlinksInPath()
        let resolvedVADURL = vadModelURL.resolvingSymlinksInPath()
        let oldMLXCacheLimit = Memory.cacheLimit
        Memory.cacheLimit = 32 * 1024 * 1024
        defer {
            Memory.clearCache()
            Memory.cacheLimit = oldMLXCacheLimit
        }

        // 创建本地 APFS 临时目录
        let localTempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("strophe_ai_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: localTempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: localTempDir)
        }

        // MARK: - Step 0: 解决安全卷权限与模型准备
        
        let scopeRoot = modelStorageRoot ?? whisperBaseDir
        let isWhisperScoped = scopeRoot.startAccessingSecurityScopedResource()
        defer {
            if isWhisperScoped { scopeRoot.stopAccessingSecurityScopedResource() }
        }

        let activeWhisperURL = try resolveModelURL(
            resolved: resolvedWhisperURL,
            tempDir: localTempDir,
            label: asrDecoderModelURL == nil ? "Qwen3-ASR" : "Qwen3-ASR CoreML Encoder"
        )

        let activeASRDecoderURL = try resolveModelURL(
            resolved: resolvedASRDecoderURL,
            tempDir: localTempDir,
            label: asrDecoderModelURL == nil ? "Qwen3-ASR Decoder" : "Qwen3-ASR MLX Decoder"
        )

        let activeAlignerURL = try resolveModelURL(
            resolved: resolvedAlignerURL,
            tempDir: localTempDir,
            label: "Qwen3-ForcedAligner"
        )

        let activeSpeakerURL = try resolveModelURL(
            resolved: resolvedVADURL,
            tempDir: localTempDir,
            label: "Pyannote VAD"
        )

        // MARK: - Step 1: 人声提取与预处理
        
        let cleanSamples16k: [Float]
        let preparedAudio16k = try BackendAudioIO.readMonoFloatWav(preparedAudio16kURL)
        
        switch vocalPreprocessing.lowercased() {
        case "none":
            print("🔊 正在读取主程序准备的 16kHz 音频...")
            progressCallback?(0, 0.5, "正在读取主程序准备的 ASR 音频...")
            cleanSamples16k = resample(preparedAudio16k.samples, from: preparedAudio16k.sampleRate, to: 16000)
            
        case "separate":
            print("🎹 正在进行伴奏与人声分离 (Spleeter)...")
            progressCallback?(0, 0.2, "正在初始化伴奏人声分离引擎...")
            guard let preparedAudio48kURL else {
                throw NSError(
                    domain: "SubtitleGenerator",
                    code: 1001,
                    userInfo: [NSLocalizedDescriptionKey: "缺少主程序准备的 48kHz 音频，无法进行人声分离。"]
                )
            }
            
            let spleeterModelId = "aufklarer/Spleeter2-CoreML"
            let spleeterCacheDir = try HuggingFaceDownloader.getCacheDirectory(for: spleeterModelId, basePath: whisperBaseDir)
            var spleeterModelURL = spleeterCacheDir.appendingPathComponent("Spleeter2Model.mlmodelc")
            if !FileManager.default.fileExists(atPath: spleeterModelURL.path) {
                let altURL = spleeterCacheDir.appendingPathComponent("Spleeter2.mlmodelc")
                if FileManager.default.fileExists(atPath: altURL.path) {
                    spleeterModelURL = altURL
                }
            }
            
            let activeSpleeterURL = try resolveModelURL(
                resolved: spleeterModelURL,
                tempDir: localTempDir,
                label: "Spleeter"
            )
            
            let separator = try AudioSeparator2(modelURL: activeSpleeterURL)
            let spleeterInputURL = localTempDir.appendingPathComponent("spleeter_input.wav")
            let vocalsWavURL = localTempDir.appendingPathComponent("vocals.wav")
            let instrumentsWavURL = localTempDir.appendingPathComponent("instruments.wav")
            let outputURLs = Stems2(vocals: vocalsWavURL, accompaniment: instrumentsWavURL)

            progressCallback?(0, 0.35, "正在读取主程序准备的人声分离音频...")
            try FileManager.default.copyItem(at: preparedAudio48kURL, to: spleeterInputURL)

            progressCallback?(0, 0.45, "正在运行伴奏人声分离，提取纯净人声...")
            for try await progress in separator.separate(from: spleeterInputURL, to: outputURLs) {
                let fraction = Double(progress.current) / Double(max(1, progress.total))
                progressCallback?(0, 0.45 + fraction * 0.35, "正在分离背景音乐 (\(Int(fraction * 100))%)...")
            }
            
            progressCallback?(0, 0.9, "人声分离完成，正在加载提取的人声音轨...")
            let vocals = try BackendAudioIO.readMonoFloatWav(vocalsWavURL)
            cleanSamples16k = resample(vocals.samples, from: vocals.sampleRate, to: 16000)
            
        default: // "denoise"
            print("🔊 正在读取主程序准备的 48kHz 音频...")
            progressCallback?(0, 0.2, "正在读取主程序准备的 48kHz 高采样率音频...")
            guard let preparedAudio48kURL else {
                throw NSError(
                    domain: "SubtitleGenerator",
                    code: 1002,
                    userInfo: [NSLocalizedDescriptionKey: "缺少主程序准备的 48kHz 音频，无法进行智能降噪。"]
                )
            }
            let rawAudio48k = try BackendAudioIO.readMonoFloatWav(preparedAudio48kURL)
            
            print("🧹 正在加载 DeepFilterNet3 智能降噪模型...")
            progressCallback?(0, 0.5, "正在初始化 ANE 加速 DeepFilterNet3 智能降噪模型...")
            let denoiserModelId = SpeechEnhancer.defaultModelId
            let denoiserCacheDir = try HuggingFaceDownloader.getCacheDirectory(for: denoiserModelId, basePath: whisperBaseDir)
            let denoiser = try await SpeechEnhancer.fromPretrained(
                modelId: denoiserModelId,
                cacheDir: denoiserCacheDir
            )
            
            print("🧹 正在进行降噪处理...")
            progressCallback?(0, 0.78, "正在过滤环境风噪与人声杂音...")
            let denoisedSamples48k = try enhanceLongAudioWithDeepFilterNet3(
                denoiser,
                samples: rawAudio48k.samples,
                sampleRate: rawAudio48k.sampleRate,
                progressCallback: progressCallback
            )
            cleanSamples16k = resample(denoisedSamples48k, from: rawAudio48k.sampleRate, to: 16000)
        }
        
        Memory.clearCache()
        progressCallback?(0, 1.0, "人声音频预处理与重采样完成。")

        // MARK: - Step 1.5: Pyannote VAD Speech Islands

        let speechRanges = try await detectSpeechIslands(
            samples: cleanSamples16k,
            sampleRate: 16000,
            vadModelURL: activeSpeakerURL,
            progressCallback: progressCallback
        )
        progressCallback?(1, 0.18, "已检测到 \(speechRanges.count) 个语音活动片段。")

        // MARK: - Step 2: Qwen3-ASR 语音转写或参考文本准备

        let referenceLines = normalizedReferenceLines(from: referenceText)
        let languageHint = language == "auto" ? nil : language
        let asrOnlySegments: [AIResultSegment]
        let rawText: String

        if referenceLines.isEmpty {
            print("🧠 正在加载 Qwen3-ASR 模型...")
            progressCallback?(1, 0.2, asrDecoderModelURL == nil ? "正在加载 Qwen3-ASR 端侧大模型 (GPU 加速)..." : "正在加载 Qwen3-ASR 混合模型 (CoreML ANE + MLX GPU)...")
            print("✍️ 正在进行语音识别转写...")
            progressCallback?(1, 0.6, "正在运行 Qwen3-ASR 音频转写文字...")
            asrOnlySegments = try await transcribeWithIsolatedASRModel(
                cacheDir: activeASRDecoderURL,
                coremlEncoderCacheDir: asrDecoderModelURL == nil ? nil : activeWhisperURL,
                samples: cleanSamples16k,
                sampleRate: 16000,
                language: languageHint,
                speechRanges: speechRanges,
                maxChunkDuration: asrChunkDuration,
                maxTokens: asrMaxTokensPerChunk,
                progressCallback: progressCallback
            )
            rawText = transcriptTextForAlignment(from: asrOnlySegments)
            Memory.clearCache()
            try? await Task.sleep(nanoseconds: 100_000_000)
            progressCallback?(1, 1.0, "语音识别转写已生成文字。")
        } else {
            print("📄 检测到参考歌词，跳过 ASR 自由转写。")
            progressCallback?(1, 0.5, "检测到参考歌词，正在准备歌词强制对齐文本...")
            asrOnlySegments = []
            rawText = referenceLines.joined(separator: "\n")
            Memory.clearCache()
            progressCallback?(
                1,
                1.0,
                "已载入 \(referenceLines.count) 行参考歌词，将直接进行强制对齐。"
            )
        }

        // MARK: - Step 3: ForcedAligner 高精度字词打轴

        var alignedWords: [AIResultSegment]
        if enableAlignment || enableDiarization {
            if alignerModelId.contains("CoreML") {
                throw NSError(
                    domain: "SubtitleGenerator",
                    code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "当前 speech-swift 版本尚未暴露 CoreML ForcedAligner 推理接口，请先选择 MLX 4-bit 对齐器。"]
                )
            }

            let alignLanguage = language == "auto" ? "zh" : language
            if referenceLines.isEmpty {
                print("🎯 正在加载 ForcedAligner 模型...")
                progressCallback?(2, 0.2, "正在初始化 ForcedAligner 字词毫秒级对齐引擎...")
                let aligner = try await Qwen3ForcedAligner.fromPretrained(
                    modelId: alignerModelId,
                    cacheDir: activeAlignerURL,
                    offlineMode: true
                )

                print("🎯 正在执行字词级强制对齐...")
                progressCallback?(2, 0.5, "正在计算字词绝对起止时间戳...")
                alignedWords = alignSegmentsInWindows(
                    aligner: aligner,
                    samples: cleanSamples16k,
                    segments: asrOnlySegments.isEmpty
                        ? makeCoarseSegments(
                            text: rawText,
                            duration: Double(cleanSamples16k.count) / 16000.0
                        )
                        : asrOnlySegments,
                    sampleRate: 16000,
                    language: alignLanguage,
                    speechRanges: speechRanges,
                    progressCallback: progressCallback
                )
            } else {
                print("🎼 正在根据人声音轨生成歌词行时间轴...")
                progressCallback?(2, 0.2, "正在检测人声音轨活跃区并铺排参考歌词...")
                let fallbackSegments = makeLyricSegmentsFromActiveRanges(
                    referenceLines: referenceLines,
                    samples: cleanSamples16k,
                    sampleRate: 16000,
                    speechRanges: speechRanges
                )

                print("🎯 正在用 ForcedAligner 提取可信歌词锚点...")
                progressCallback?(2, 0.45, "正在用 ForcedAligner 提取可信歌词锚点...")
                let aligner = try await Qwen3ForcedAligner.fromPretrained(
                    modelId: alignerModelId,
                    cacheDir: activeAlignerURL,
                    offlineMode: true
                )
                let alignedLineSegments = alignReferenceLinesInWindows(
                    aligner: aligner,
                    samples: cleanSamples16k,
                    referenceLines: referenceLines,
                    sampleRate: 16000,
                    language: alignLanguage,
                    speechRanges: speechRanges,
                    progressCallback: progressCallback
                )
                let audioDuration = Double(cleanSamples16k.count) / 16000.0
                alignedWords = mergeHybridLyricSegments(
                    alignedLineSegments: alignedLineSegments,
                    fallbackSegments: fallbackSegments,
                    audioDuration: audioDuration
                )
            }
            progressCallback?(2, 1.0, "字词高精度时间轴对齐完毕。")
        } else {
            print("⏭️ 已关闭精确对齐，仅使用 Qwen3-ASR 文本生成粗略字幕片段。")
            progressCallback?(2, 1.0, "已跳过 ForcedAligner，仅使用 Qwen3-ASR 输出粗略时间轴。")
            let duration = Double(cleanSamples16k.count) / 16000.0
            alignedWords = asrOnlySegments.isEmpty ? makeCoarseSegments(text: rawText, duration: duration) : asrOnlySegments
        }

        // MARK: - Step 4: Speaker Diarization 对话人声纹分离

        if enableDiarization {
            print("👥 正在加载 Pyannote 声纹分离模型...")
            progressCallback?(3, 0.2, "正在加载 Pyannote 说话人分离与声纹日志模型...")
            let diarizer = try await DiarizationPipeline.fromPretrained(cacheBaseDir: speakerBaseDir)
            
            print("🗣️ 正在进行说话人角色分析...")
            progressCallback?(3, 0.5, "正在提取并分析多发言人特征声纹...")
            let diarizationSegments = diarizer.diarize(audio: cleanSamples16k, sampleRate: 16000)
            
            print("🔗 正在合并字词与发言人信息...")
            progressCallback?(3, 0.8, "正在执行声纹特征与字词区间高精度碰撞计算...")
            
            var matchedWords: [AIResultSegment] = []
            for word in alignedWords {
                let wordMid = (word.startTime + word.endTime) / 2.0
                var speakerText = "Unknown"
                
                // 根据时间区间将字词归属到对应的发言人
                if let match = diarizationSegments.first(where: { wordMid >= Double($0.startTime) && wordMid <= Double($0.endTime) }) {
                    speakerText = "Speaker \(match.speakerId)"
                }
                
                let text = "[\(speakerText)] \(word.text)"
                matchedWords.append(AIResultSegment(
                    text: text,
                    startTime: word.startTime,
                    endTime: word.endTime
                ))
            }
            alignedWords = matchedWords
        }

        // MARK: - Step 5: 最终字幕块组装

        progressCallback?(3, 0.9, "正在整合最终的字幕片段...")
        var finalSegments = referenceLines.isEmpty
            ? mergeWordsToSegments(
                words: alignedWords,
                maxGap: 0.9,
                maxDuration: 7.0,
                preferredChars: 18,
                maxChars: 26,
                includeSpeakerLabel: prefixSpeakerName
            )
            : alignedWords

        if !referenceLines.isEmpty {
            progressCallback?(3, 0.95, "正在把歌词块边界吸附到人声能量边缘...")
            finalSegments = snapSegmentsToVocalEnergy(
                finalSegments,
                samples: cleanSamples16k,
                sampleRate: 16000
            )
        }

        finalSegments = clampOverlapsToNextStart(finalSegments)
        
        progressCallback?(3, 1.0, "Golden Pipeline 字幕流程全部处理就绪。")
        print("✅ 字幕生成完毕，共生成 \(finalSegments.count) 条！")
        return finalSegments
    }

    // MARK: - Private Helpers

    /// 根据卷格式决定是否复制模型到本地 APFS 临时目录
    private func resolveModelURL(resolved: URL, tempDir: URL, label: String) throws -> URL {
        guard resolved.path.hasPrefix("/Volumes/") else {
            return resolved
        }

        let fsType = volumeFilesystemType(at: resolved)
        let nativeFSTypes = ["apfs", "hfs"]

        if nativeFSTypes.contains(fsType) {
            print("✅ \(label) 模型所在卷格式为 \(fsType.uppercased())，CoreML 可直接访问，跳过复制。")
            return resolved
        }

        print("💾 \(label) 模型所在卷格式为 \(fsType.uppercased())，正在建立本地 APFS 临时副本以规避 CoreML mmap 限制...")
        let tempURL = tempDir.appendingPathComponent(resolved.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: resolved, to: tempURL)
            print("   ✓ 复制完成: \(tempURL.path)")
            return tempURL
        } catch {
            print("⚠️ 建立本地 \(label) 副本失败，尝试直接以原路径加载: \(error.localizedDescription)")
            return resolved
        }
    }
}
