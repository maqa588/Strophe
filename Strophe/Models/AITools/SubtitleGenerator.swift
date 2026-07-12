//
//  SubtitleGenerator.swift
//  Strophe
//

import Foundation

actor SubtitleGenerator {
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
        alignerModelId: String = "aufklarer/Qwen3-ForcedAligner-0.6B-CoreML-INT8",
        modelStorageRoot: URL? = nil,
        expectedSpeakers: Int? = nil,
        language: String = "auto",
        enableDiarization: Bool = false,
        prefixSpeakerName: Bool = false,
        enableAlignment: Bool = true,
        vocalPreprocessing: String = "none",
        referenceText: String? = nil,
        useVAD: Bool = true,
        progressCallback: (@Sendable (Int, Double, String) -> Void)? = nil
    ) async throws -> [AIResultSegment] {
        #if STROPHE_LOCAL_AI
        guard #available(iOS 18.0, macOS 15.0, *) else {
            throw NSError(domain: "SubtitleGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "本地 AI 需要 iOS 18 或 macOS 15 以上 system。"])
        }
        _ = (preparedAudio48kURL, asrDecoderModelURL, speakerModelURL,
             whisperBaseDir, alignerBaseDir, speakerBaseDir, alignerModelId,
             modelStorageRoot, expectedSpeakers, prefixSpeakerName, vocalPreprocessing, referenceText)
        if enableDiarization {
            throw NSError(domain: "SubtitleGenerator", code: 2, userInfo: [NSLocalizedDescriptionKey: "纯 CoreML 版本暂不包含说话人分离，请关闭该选项。"])
        }

        progressCallback?(0, 0.1, "正在读取音频...")
        let samples = try await AudioExtractor.extract(from: preparedAudio16kURL, targetSampleRate: 16_000)
        guard !samples.isEmpty else {
            throw NSError(domain: "SubtitleGenerator", code: 3, userInfo: [NSLocalizedDescriptionKey: "输入音频为空。"])
        }

        progressCallback?(0, 0.4, useVAD ? "正在进行 VAD 语音活动检测..." : "正在进行分段切分...")
        let islands: [CoreMLFireRedVAD.VoiceIsland]
        if useVAD {
            // Keep VAD in a nested scope so its Core ML model is released before
            // the much larger ASR model is loaded.
            let rawIslands = try autoreleasepool {
                let vad = try CoreMLFireRedVAD(directory: vadModelURL)
                return try vad.findVoiceIslands(samples: samples)
            }
            // Twenty-second chunks leave more headroom on 4 GB iPhones and keep
            // ForcedAligner decoder sequences comfortably within their budget.
            let merged = Self.mergeIslands(rawIslands, gapSamples: 24000, maxSamples: 320000)
            islands = Self.splitIslands(merged, maxSamples: 320000)
            print("VAD: \(rawIslands.count) 个原始岛 → 合并为 \(islands.count) 个语音块")
        } else {
            // Cut uniformly into 20-second segments (320000 samples at 16kHz)
            var uniformIslands: [CoreMLFireRedVAD.VoiceIsland] = []
            let chunkSamples = 320000
            var offset = 0
            while offset < samples.count {
                let end = min(samples.count, offset + chunkSamples)
                if (end - offset) >= 8000 {
                    uniformIslands.append(CoreMLFireRedVAD.VoiceIsland(startSample: offset, endSample: end))
                } else if !uniformIslands.isEmpty {
                    let lastIdx = uniformIslands.count - 1
                    uniformIslands[lastIdx] = CoreMLFireRedVAD.VoiceIsland(startSample: uniformIslands[lastIdx].startSample, endSample: end)
                } else {
                    uniformIslands.append(CoreMLFireRedVAD.VoiceIsland(startSample: offset, endSample: end))
                }
                offset += chunkSamples
            }
            islands = uniformIslands
            print("VAD Disabled: 均匀切分为 \(islands.count) 个语音块")
        }
        
        var results: [AIResultSegment] = []
        var transcripts: [(island: CoreMLFireRedVAD.VoiceIsland, text: String)] = []
        let modelLanguage = Self.modelLanguageName(for: language)

        // Pass 1: transcribe every chunk. The ASR object goes out of scope before
        // ForcedAligner is constructed, preventing both large model families
        // from being resident at the same time.
        try autoreleasepool {
            progressCallback?(0, 0.3, "正在加载 Qwen3-ASR CoreML 模型...")
            let asr = try CoreMLQwen3ASR(directory: whisperModelURL)
            for (idx, island) in islands.enumerated() {
                try Task.checkCancellation()
                progressCallback?(1, Double(idx) / Double(max(1, islands.count)), "正在识别第 \(idx + 1)/\(islands.count) 个语音段...")
                let chunk = Array(samples[island.startSample..<island.endSample])
                let text = try autoreleasepool {
                    let raw = try asr.transcribe(audio: chunk, language: modelLanguage)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return Self.stripPromptLeakage(from: raw)
                }
                guard !text.isEmpty else { continue }
                transcripts.append((island, text))
                if !enableAlignment {
                    results.append(AIResultSegment(
                        text: text,
                        startTime: island.startTime,
                        endTime: island.endTime
                    ))
                }
            }
        }

        if enableAlignment {
            // Pass 2: ASR has been released; only now load ForcedAligner.
            progressCallback?(1, 0, "正在加载 ForcedAligner CoreML 模型...")
            var globallyAlignedWords: [Qwen3AlignedWord] = []
            let aligner = try CoreMLQwen3ForcedAligner(directory: alignerModelURL)
            for (idx, transcript) in transcripts.enumerated() {
                try Task.checkCancellation()
                progressCallback?(2, Double(idx) / Double(max(1, transcripts.count)), "正在对齐第 \(idx + 1)/\(transcripts.count) 个语音段...")
                let island = transcript.island
                let chunk = Array(samples[island.startSample..<island.endSample])
                let words = try autoreleasepool {
                    try aligner.align(
                        audio: chunk,
                        text: transcript.text,
                        language: modelLanguage ?? language
                    )
                }
                globallyAlignedWords.append(contentsOf: words.map {
                    Qwen3AlignedWord(
                        text: $0.text,
                        start: $0.start + island.startTime,
                        end: $0.end + island.startTime
                    )
                })
            }
            globallyAlignedWords.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
            results = Self.makeSegments(words: globallyAlignedWords)
        }
        progressCallback?(3, 1, "字幕时间轴生成完成")
        return results
        #else
        throw NSError(domain: "SubtitleGenerator", code: 4, userInfo: [NSLocalizedDescriptionKey: "当前构建未包含本地 AI。"])
        #endif
    }

    #if STROPHE_LOCAL_AI
    /// 移除 Qwen3-ASR 偶发泄漏的 prompt 指令伪影（如 "language None"）。
    private static func stripPromptLeakage(from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "language\\s+None", options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        let result = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transcribe and align a chunk, recursively splitting only when the text plus
    /// audio embeddings exceed the ForcedAligner decoder's sequence budget.
    @available(iOS 18.0, macOS 15.0, *)
    private static func transcribeAndAlign(
        audio: [Float],
        offset: Double,
        asr: CoreMLQwen3ASR,
        aligner: CoreMLQwen3ForcedAligner,
        language: String,
        depth: Int = 0
    ) throws -> [Qwen3AlignedWord] {
        let raw = try asr.transcribe(audio: audio, language: language)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = stripPromptLeakage(from: raw)
        guard !text.isEmpty else { return [] }

        do {
            return try aligner.align(audio: audio, text: text, language: language).map {
                Qwen3AlignedWord(text: $0.text, start: $0.start + offset, end: $0.end + offset)
            }
        } catch CoreMLQwen3Error.inference(let message)
                    where message.contains("ForcedAligner token 数量") && depth < 5 && audio.count >= 32_000 {
            // Re-transcribe each half: splitting text alone cannot reliably determine
            // which words belong to which audio interval.
            let middle = audio.count / 2
            let left = Array(audio[..<middle])
            let right = Array(audio[middle...])
            let leftWords = try transcribeAndAlign(
                audio: left,
                offset: offset,
                asr: asr,
                aligner: aligner,
                language: language,
                depth: depth + 1
            )
            let rightWords = try transcribeAndAlign(
                audio: right,
                offset: offset + Double(middle) / 16_000.0,
                asr: asr,
                aligner: aligner,
                language: language,
                depth: depth + 1
            )
            return leftWords + rightWords
        }
    }

    /// Merge nearby VAD islands into super-islands to reduce fragmentation.
    /// - Parameters:
    ///   - islands: Raw islands from FireRedVAD
    ///   - gapSamples: Max allowed silence gap between islands to merge (default 1.5 s = 24000)
    ///   - maxSamples: Hard cap on merged island length (default 30 s = 480000)
    @available(iOS 18.0, macOS 15.0, *)
    private static func mergeIslands(
        _ islands: [CoreMLFireRedVAD.VoiceIsland],
        gapSamples: Int,
        maxSamples: Int
    ) -> [CoreMLFireRedVAD.VoiceIsland] {
        guard !islands.isEmpty else { return [] }
        var merged: [CoreMLFireRedVAD.VoiceIsland] = []
        var current = islands[0]
        for next in islands.dropFirst() {
            let gap = next.startSample - current.endSample
            let combined = next.endSample - current.startSample
            if gap <= gapSamples && combined <= maxSamples {
                current = CoreMLFireRedVAD.VoiceIsland(startSample: current.startSample, endSample: next.endSample)
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }

    @available(iOS 18.0, macOS 15.0, *)
    private static func splitIslands(
        _ islands: [CoreMLFireRedVAD.VoiceIsland],
        maxSamples: Int
    ) -> [CoreMLFireRedVAD.VoiceIsland] {
        guard maxSamples > 0 else { return islands }
        var result: [CoreMLFireRedVAD.VoiceIsland] = []
        for island in islands {
            var start = island.startSample
            while start < island.endSample {
                let end = min(island.endSample, start + maxSamples)
                result.append(CoreMLFireRedVAD.VoiceIsland(startSample: start, endSample: end))
                start = end
            }
        }
        return result
    }

    private static func makeSegments(words: [Qwen3AlignedWord]) -> [AIResultSegment] {
        guard !words.isEmpty else { return [] }
        var segments: [AIResultSegment] = []
        var buffer: [Qwen3AlignedWord] = []

        func flush() {
            guard let first = buffer.first, let last = buffer.last else { return }
            let text = joinedText(buffer.map(\.text))
            if !text.isEmpty {
                segments.append(AIResultSegment(
                    text: text,
                    startTime: first.start,
                    endTime: max(last.end, first.start + 0.08)
                ))
            }
            buffer.removeAll(keepingCapacity: true)
        }

        for (index, word) in words.enumerated() {
            buffer.append(word)
            let text = joinedText(buffer.map(\.text))
            let terminal = word.text.last.map { "。；？！?!;".contains($0) } ?? false
            let comma = word.text.last.map { "，、,".contains($0) } ?? false
            let nextGap = index + 1 < words.count ? words[index + 1].start - word.end : 0
            var shouldSplit = terminal || (comma && buffer.count >= 10) || nextGap > 1

            if text.count >= 22 && !shouldSplit {
                var naturalSplitSoon = false
                let upper = min(words.count, index + 4)
                if index + 1 < upper {
                    for lookahead in (index + 1)..<upper {
                        let candidate = words[lookahead]
                        if candidate.text.last.map({ "，。、；？！,.?;!".contains($0) }) == true ||
                            candidate.start - words[lookahead - 1].end > 0.5 {
                            naturalSplitSoon = true
                            break
                        }
                    }
                }
                shouldSplit = !naturalSplitSoon
            }
            if shouldSplit { flush() }
        }
        flush()
        return segments
    }

    private static func joinedText(_ words: [String]) -> String {
        var result = ""
        for word in words {
            let isCJK = word.unicodeScalars.contains { (0x3000...0x9FFF).contains(Int($0.value)) }
            if !result.isEmpty && !isCJK && !(word.first.map { ",.!?;:，。！？；：".contains($0) } ?? false) { result.append(" ") }
            result.append(word)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func modelLanguageName(for language: String) -> String? {
        let normalized = language.lowercased()
        if normalized.isEmpty || normalized == "auto" { return nil }
        let names: [String: String] = [
            "zh": "Chinese", "zh-cn": "Chinese", "zh-tw": "Chinese", "zh-hk": "Cantonese",
            "en": "English", "ja": "Japanese", "ko": "Korean", "fr": "French",
            "de": "German", "es": "Spanish", "ru": "Russian", "ar": "Arabic",
            "pt": "Portuguese", "id": "Indonesian", "it": "Italian", "th": "Thai",
            "vi": "Vietnamese", "tr": "Turkish", "hi": "Hindi", "ms": "Malay",
            "nl": "Dutch", "sv": "Swedish", "da": "Danish", "fi": "Finnish",
            "pl": "Polish", "cs": "Czech", "fil": "Filipino", "fa": "Persian",
            "el": "Greek", "ro": "Romanian", "hu": "Hungarian", "mk": "Macedonian"
        ]
        if let mapped = names[normalized] { return mapped }
        return language.prefix(1).uppercased() + language.dropFirst()
    }
    #endif
}
