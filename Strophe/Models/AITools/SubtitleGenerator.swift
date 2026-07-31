//
//  SubtitleGenerator.swift
//  Strophe
//

import Foundation

actor SubtitleGenerator {
    func generateDiarizedSubtitles(
        preparedAudio16kURL: URL,
        preparedAudio48kURL: URL?,
        asrModelName: String,
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
                throw NSError(
                    domain: "SubtitleGenerator", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "本地 AI 需要 iOS 18 或 macOS 15 以上 system。"])
            }
            _ = (
                preparedAudio48kURL, asrDecoderModelURL, speakerModelURL,
                whisperBaseDir, alignerBaseDir, speakerBaseDir, alignerModelId,
                modelStorageRoot, expectedSpeakers, prefixSpeakerName, vocalPreprocessing, referenceText
            )
            if enableDiarization {
                throw NSError(
                    domain: "SubtitleGenerator", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "纯 CoreML 版本暂不包含说话人分离，请关闭该选项。"])
            }

            progressCallback?(
                0,
                0.1,
                NSLocalizedString("status_reading_audio", comment: "ASR progress")
            )
            let samples = try await AudioExtractor.extract(from: preparedAudio16kURL, targetSampleRate: 16_000)
            guard !samples.isEmpty else {
                throw NSError(domain: "SubtitleGenerator", code: 3, userInfo: [NSLocalizedDescriptionKey: "输入音频为空。"])
            }

            progressCallback?(
                0,
                0.4,
                NSLocalizedString(
                    useVAD ? "status_running_vad" : "status_segmenting_audio",
                    comment: "ASR progress"
                )
            )
            let islands: [CoreMLFireRedVAD.VoiceIsland]
            let vadRecoveryRanges: [ParakeetAdaptiveRecovery.TimeRange]
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
                vadRecoveryRanges = rawIslands.map {
                    ParakeetAdaptiveRecovery.TimeRange(
                        start: $0.startTime,
                        end: $0.endTime
                    )
                }
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
                        uniformIslands[lastIdx] = CoreMLFireRedVAD.VoiceIsland(
                            startSample: uniformIslands[lastIdx].startSample, endSample: end)
                    } else {
                        uniformIslands.append(CoreMLFireRedVAD.VoiceIsland(startSample: offset, endSample: end))
                    }
                    offset += chunkSamples
                }
                islands = uniformIslands
                vadRecoveryRanges = []
                print("VAD Disabled: 均匀切分为 \(islands.count) 个语音块")
            }

            let usesParakeetNativeTimestamps = LocalModelManager.isParakeetJA(
                asrModelName
            )
            var results: [AIResultSegment] = []
            var transcripts: [(island: CoreMLFireRedVAD.VoiceIsland, text: String)] = []
            var nativeTimedTokens: [SubtitleWordTiming] = []
            let modelLanguage = Self.modelLanguageName(for: language)

            // Pass 1: transcribe every chunk. The ASR object goes out of scope before
            // ForcedAligner is constructed, preventing both large model families
            // from being resident at the same time.
            if usesParakeetNativeTimestamps {
                try autoreleasepool {
                    progressCallback?(
                        0,
                        0.3,
                        NSLocalizedString(
                            "status_loading_parakeet",
                            comment: "ASR progress"
                        )
                    )
                    let asr = try CoreMLParakeetJA(directory: whisperModelURL)
                    for (idx, island) in islands.enumerated() {
                        try Task.checkCancellation()
                        progressCallback?(
                            1,
                            Double(idx) / Double(max(1, islands.count)),
                            String(
                                format: NSLocalizedString(
                                    "status_recognizing_parakeet_format",
                                    comment: "ASR progress"
                                ),
                                idx + 1,
                                islands.count
                            )
                        )
                        let chunk = Array(
                            samples[island.startSample..<island.endSample]
                        )
                        let transcription = try autoreleasepool {
                            try asr.transcribe(audio: chunk)
                        }
                        guard !transcription.text.isEmpty else { continue }
                        nativeTimedTokens.append(
                            contentsOf: transcription.tokenTimings.map {
                                SubtitleWordTiming(
                                    text: $0.text,
                                    startTime: $0.startTime + island.startTime,
                                    endTime: $0.endTime + island.startTime
                                )
                            }
                        )
                    }

                    let recoveryConfiguration = ParakeetAdaptiveRecovery.Configuration()
                    let initialMissingRanges = ParakeetAdaptiveRecovery.missingSpeechRanges(
                        speechRanges: vadRecoveryRanges,
                        tokenRanges: nativeTimedTokens.map {
                            ParakeetAdaptiveRecovery.TimeRange(
                                start: $0.startTime,
                                end: $0.endTime
                            )
                        },
                        minimumDuration: recoveryConfiguration.minimumMissingDuration
                    )
                    if !initialMissingRanges.isEmpty {
                        print(
                            "Parakeet-JA: 检测到 \(initialMissingRanges.count) 个 VAD 有声但无 token 的区间，开始自适应补漏"
                        )
                    }
                    let audioDuration = Double(samples.count) / 16_000.0
                    for (index, missing) in initialMissingRanges.enumerated() {
                        try Task.checkCancellation()
                        progressCallback?(
                            1,
                            0.9 + 0.09 * Double(index) / Double(max(1, initialMissingRanges.count)),
                            String(
                                format: NSLocalizedString(
                                    "status_recovering_parakeet_gaps_format",
                                    comment: "ASR recovery progress"
                                ),
                                index + 1,
                                initialMissingRanges.count
                            )
                        )

                        let contextual = ParakeetAdaptiveRecovery.contextualWindow(
                            for: missing,
                            audioDuration: audioDuration,
                            configuration: recoveryConfiguration
                        )
                        Self.appendParakeetRecoveryTokens(
                            try Self.transcribeParakeetRecoveryWindow(
                                contextual,
                                samples: samples,
                                asr: asr
                            ),
                            acceptance: contextual.acceptance,
                            to: &nativeTimedTokens
                        )

                        // A broad ±4-second retry usually restores the missing
                        // sentence. If any one-second token-free portion remains,
                        // deliberately reposition it near the start of a fixed
                        // encoder window and retry only that residual portion.
                        let residualRanges = ParakeetAdaptiveRecovery.missingSpeechRanges(
                            speechRanges: [missing],
                            tokenRanges: nativeTimedTokens.map {
                                ParakeetAdaptiveRecovery.TimeRange(
                                    start: $0.startTime,
                                    end: $0.endTime
                                )
                            },
                            minimumDuration: recoveryConfiguration.minimumMissingDuration
                        )
                        for residual in residualRanges {
                            for shifted in ParakeetAdaptiveRecovery.shiftedWindows(
                                for: residual,
                                audioDuration: audioDuration,
                                configuration: recoveryConfiguration
                            ) {
                                try Task.checkCancellation()
                                Self.appendParakeetRecoveryTokens(
                                    try Self.transcribeParakeetRecoveryWindow(
                                        shifted,
                                        samples: samples,
                                        asr: asr
                                    ),
                                    acceptance: shifted.acceptance,
                                    to: &nativeTimedTokens
                                )
                            }
                        }
                    }
                    nativeTimedTokens.sort {
                        $0.startTime == $1.startTime
                            ? $0.endTime < $1.endTime
                            : $0.startTime < $1.startTime
                    }
                }
                results = SubtitleSegmentation.makeSegments(words: nativeTimedTokens)
            } else {
                try autoreleasepool {
                    progressCallback?(
                        0,
                        0.3,
                        NSLocalizedString(
                            "status_loading_qwen3_asr",
                            comment: "ASR progress"
                        )
                    )
                    let asr = try CoreMLQwen3ASR(directory: whisperModelURL)
                    for (idx, island) in islands.enumerated() {
                        try Task.checkCancellation()
                        progressCallback?(
                            1,
                            Double(idx) / Double(max(1, islands.count)),
                            String(
                                format: NSLocalizedString(
                                    "status_recognizing_segment_format",
                                    comment: "ASR progress"
                                ),
                                idx + 1,
                                islands.count
                            )
                        )
                        let chunk = Array(samples[island.startSample..<island.endSample])
                        let text = try autoreleasepool {
                            let raw = try asr.transcribe(audio: chunk, language: modelLanguage)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            return Self.stripPromptLeakage(from: raw)
                        }
                        guard !text.isEmpty else { continue }
                        transcripts.append((island, text))
                        if !enableAlignment {
                            results.append(
                                AIResultSegment(
                                    text: text,
                                    startTime: island.startTime,
                                    endTime: island.endTime
                                ))
                        }
                    }
                }
            }

            if enableAlignment && !usesParakeetNativeTimestamps {
                // Pass 2: ASR has been released; only now load ForcedAligner.
                progressCallback?(
                    1,
                    0,
                    NSLocalizedString(
                        "status_loading_forced_aligner",
                        comment: "Alignment progress"
                    )
                )
                var globallyAlignedWords: [Qwen3AlignedWord] = []
                let aligner = try CoreMLQwen3ForcedAligner(directory: alignerModelURL)
                for (idx, transcript) in transcripts.enumerated() {
                    try Task.checkCancellation()
                    progressCallback?(
                        2,
                        Double(idx) / Double(max(1, transcripts.count)),
                        String(
                            format: NSLocalizedString(
                                "status_aligning_segment_format",
                                comment: "Alignment progress"
                            ),
                            idx + 1,
                            transcripts.count
                        )
                    )
                    let island = transcript.island
                    let chunk = Array(samples[island.startSample..<island.endSample])
                    let words = try autoreleasepool {
                        try aligner.align(
                            audio: chunk,
                            text: transcript.text,
                            language: modelLanguage ?? language
                        )
                    }
                    globallyAlignedWords.append(
                        contentsOf: words.map {
                            Qwen3AlignedWord(
                                text: $0.text,
                                start: $0.start + island.startTime,
                                end: $0.end + island.startTime
                            )
                        })
                }
                globallyAlignedWords.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
                let timedWords = globallyAlignedWords.map {
                    SubtitleWordTiming(text: $0.text, startTime: $0.start, endTime: $0.end)
                }
                results = SubtitleSegmentation.makeSegments(words: timedWords)
            }
            results = SubtitleSegmentation.smoothTimeline(
                results,
                threshold: SubtitleSegmentation.configuredContinuityThreshold
            )
            let outputStep = usesParakeetNativeTimestamps || !enableAlignment ? 2 : 3
            progressCallback?(
                outputStep,
                1,
                NSLocalizedString(
                    "status_subtitle_timeline_complete",
                    comment: "Subtitle generation completed"
                )
            )
            return results
        #else
            throw NSError(domain: "SubtitleGenerator", code: 4, userInfo: [NSLocalizedDescriptionKey: "当前构建未包含本地 AI。"])
        #endif
    }

    #if STROPHE_LOCAL_AI
        @available(iOS 18.0, macOS 15.0, *)
        private static func transcribeParakeetRecoveryWindow(
            _ window: ParakeetAdaptiveRecovery.RetryWindow,
            samples: [Float],
            asr: CoreMLParakeetJA
        ) throws -> [SubtitleWordTiming] {
            let sampleRate = 16_000.0
            let startSample = max(
                0,
                min(samples.count, Int(floor(window.audio.start * sampleRate)))
            )
            let endSample = max(
                startSample,
                min(samples.count, Int(ceil(window.audio.end * sampleRate)))
            )
            guard endSample > startSample else { return [] }

            let transcription = try autoreleasepool {
                try asr.transcribe(audio: Array(samples[startSample..<endSample]))
            }
            let offset = Double(startSample) / sampleRate
            return transcription.tokenTimings.compactMap {
                let timing = SubtitleWordTiming(
                    text: $0.text,
                    startTime: $0.startTime + offset,
                    endTime: $0.endTime + offset
                )
                let center = (timing.startTime + timing.endTime) / 2
                // FireRedVAD boundaries include only 250 ms of padding. Keep a
                // little more leading room so the first Japanese subword is not clipped.
                guard center >= window.acceptance.start - 0.35,
                    center < window.acceptance.end
                else {
                    return nil
                }
                return timing
            }
        }

        private static func appendParakeetRecoveryTokens(
            _ recoveredTokens: [SubtitleWordTiming],
            acceptance: ParakeetAdaptiveRecovery.TimeRange,
            to existingTokens: inout [SubtitleWordTiming]
        ) {
            guard !recoveredTokens.isEmpty else { return }
            var recovered = recoveredTokens.sorted {
                $0.startTime == $1.startTime
                    ? $0.endTime < $1.endTime
                    : $0.startTime < $1.startTime
            }
            let existing = existingTokens.sorted {
                $0.startTime == $1.startTime
                    ? $0.endTime < $1.endTime
                    : $0.startTime < $1.startTime
            }

            // A recovery window deliberately overlaps the original pass. Remove
            // identical token sequences at both stitching boundaries while
            // preserving repeated tokens produced inside the recovered sentence.
            let previous = existing.filter {
                ($0.startTime + $0.endTime) / 2 < acceptance.start
            }
            if let previousEnd = previous.last?.endTime,
                let recoveredStart = recovered.first?.startTime,
                recoveredStart - previousEnd <= 1.0
            {
                let overlap = tokenOverlapCount(
                    suffixOf: previous,
                    prefixOf: recovered
                )
                if overlap > 0 {
                    recovered.removeFirst(overlap)
                }
            }

            let following = existing.filter {
                ($0.startTime + $0.endTime) / 2 >= acceptance.end
            }
            if let recoveredEnd = recovered.last?.endTime,
                let followingStart = following.first?.startTime,
                followingStart - recoveredEnd <= 0.5
            {
                let overlap = tokenOverlapCount(
                    suffixOf: recovered,
                    prefixOf: following
                )
                if overlap > 0 {
                    recovered.removeLast(overlap)
                }
            }

            existingTokens.append(contentsOf: recovered)
        }

        private static func tokenOverlapCount(
            suffixOf left: [SubtitleWordTiming],
            prefixOf right: [SubtitleWordTiming]
        ) -> Int {
            let limit = min(12, left.count, right.count)
            guard limit > 0 else { return 0 }
            for count in stride(from: limit, through: 1, by: -1) {
                if left.suffix(count).map(\.text) == right.prefix(count).map(\.text) {
                    return count
                }
            }
            return 0
        }

        /// Removes prompt instructions that Qwen3-ASR occasionally emits as transcript text.
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
                where message.contains("ForcedAligner token 数量") && depth < 5 && audio.count >= 32_000
            {
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
                "el": "Greek", "ro": "Romanian", "hu": "Hungarian", "mk": "Macedonian",
            ]
            if let mapped = names[normalized] { return mapped }
            return language.prefix(1).uppercased() + language.dropFirst()
        }
    #endif
}
