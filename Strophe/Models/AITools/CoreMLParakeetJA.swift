#if STROPHE_LOCAL_AI
    @preconcurrency import CoreML
    import Foundation

    /// One timestamped Japanese SentencePiece token emitted by Parakeet TDT.
    nonisolated struct ParakeetJATokenTiming: Sendable, Equatable {
        let text: String
        let startTime: Double
        let endTime: Double
        let confidence: Float
    }

    nonisolated struct ParakeetJATranscription: Sendable, Equatable {
        let text: String
        let tokenTimings: [ParakeetJATokenTiming]
    }

    nonisolated enum CoreMLParakeetJAError: LocalizedError {
        case model(String)
        case inference(String)
        case vocabulary(String)

        var errorDescription: String? {
            switch self {
            case .model(let message): return "Parakeet-JA 模型加载失败：\(message)"
            case .inference(let message): return "Parakeet-JA 推理失败：\(message)"
            case .vocabulary(let message): return "Parakeet-JA 词表加载失败：\(message)"
            }
        }
    }

    /// Dependency-free Swift/CoreML inference for
    /// `FluidInference/parakeet-0.6b-ja-coreml`.
    ///
    /// The TDT greedy-decoding behavior follows NVIDIA's Token-and-Duration
    /// Transducer algorithm. FluidAudio (Apache-2.0) was used as a behavioral
    /// reference while validating tensor layouts and duration/timestamp handling;
    /// Strophe does not link or import FluidAudio.
    @available(macOS 15.0, iOS 18.0, *)
    nonisolated final class CoreMLParakeetJA: @unchecked Sendable {
        private static let sampleRate = 16_000
        private static let maximumSamples = 240_000  // 15 seconds
        private static let overlapSamples = 32_000  // 2 seconds
        private static let windowStride = maximumSamples - overlapSamples
        private static let encoderHiddenSize = 1_024
        private static let decoderHiddenSize = 640
        private static let decoderLayers = 2
        private static let blankTokenID = 3_072
        private static let frameDuration = 0.08
        private static let maximumSymbolsPerFrame = 8
        private static let maximumTokensPerWindow = 1_024

        private let preprocessor: MLModel
        private let encoder: MLModel
        private let decoder: MLModel
        private let joint: MLModel
        private let vocabulary: [String]

        private struct ModelStack {
            let preprocessor: MLModel
            let encoder: MLModel
            let decoder: MLModel
            let joint: MLModel
        }

        private struct DecoderState {
            var hidden: MLMultiArray
            var cell: MLMultiArray
            var predictor: MLMultiArray
        }

        init(directory: URL) throws {
            let models = try Self.loadModels(from: directory)
            preprocessor = models.preprocessor
            encoder = models.encoder
            decoder = models.decoder
            joint = models.joint

            let vocabularyURL = directory.appendingPathComponent("vocab.json")
            do {
                let data = try Data(contentsOf: vocabularyURL)
                vocabulary = try JSONDecoder().decode([String].self, from: data)
            } catch {
                throw CoreMLParakeetJAError.vocabulary(error.localizedDescription)
            }
            guard vocabulary.count == Self.blankTokenID else {
                throw CoreMLParakeetJAError.vocabulary(
                    "预期 \(Self.blankTokenID) 个 token，实际为 \(vocabulary.count)"
                )
            }
        }

        /// Transcribes arbitrary-length 16 kHz mono Float32 audio.
        ///
        /// The CoreML encoder has a fixed 15-second input. Longer input is decoded
        /// in 15-second windows with a 2-second overlap; token centers are assigned
        /// across the overlap midpoint so duplicated boundary tokens are removed.
        func transcribe(audio: [Float]) throws -> ParakeetJATranscription {
            guard !audio.isEmpty else {
                return ParakeetJATranscription(text: "", tokenTimings: [])
            }

            let starts = Self.windowStarts(sampleCount: audio.count)
            let totalDuration = Double(audio.count) / Double(Self.sampleRate)
            var merged: [ParakeetJATokenTiming] = []

            for (index, startSample) in starts.enumerated() {
                let endSample = min(audio.count, startSample + Self.maximumSamples)
                let localAudio = Array(audio[startSample..<endSample])
                let localTimings = try transcribeWindow(localAudio)
                let windowOffset = Double(startSample) / Double(Self.sampleRate)

                let acceptedStart =
                    index == 0
                    ? 0
                    : windowOffset + Double(Self.overlapSamples) / Double(Self.sampleRate) / 2
                let acceptedEnd: Double
                if index + 1 < starts.count {
                    let nextOffset = Double(starts[index + 1]) / Double(Self.sampleRate)
                    acceptedEnd =
                        nextOffset
                        + Double(Self.overlapSamples) / Double(Self.sampleRate) / 2
                } else {
                    acceptedEnd = totalDuration + Self.frameDuration
                }

                var accepted: [ParakeetJATokenTiming] = []
                for timing in localTimings {
                    let globalStart = timing.startTime + windowOffset
                    let globalEnd = min(totalDuration, timing.endTime + windowOffset)
                    let center = (globalStart + globalEnd) / 2
                    guard center >= acceptedStart, center < acceptedEnd else { continue }
                    accepted.append(
                        ParakeetJATokenTiming(
                            text: timing.text,
                            startTime: globalStart,
                            endTime: min(
                                totalDuration,
                                max(globalStart + Self.frameDuration, globalEnd)
                            ),
                            confidence: timing.confidence
                        )
                    )
                }
                if index > 0 {
                    accepted.removeFirst(
                        Self.duplicateTokenPrefixLength(
                            existing: merged,
                            incoming: accepted
                        )
                    )
                }
                merged.append(contentsOf: accepted)
            }

            merged.sort {
                $0.startTime == $1.startTime
                    ? $0.endTime < $1.endTime
                    : $0.startTime < $1.startTime
            }
            let text = Self.normalizedText(from: merged.map(\.text))
            return ParakeetJATranscription(text: text, tokenTimings: merged)
        }

        // MARK: - Fixed-window inference

        private func transcribeWindow(_ audio: [Float]) throws -> [ParakeetJATokenTiming] {
            guard !audio.isEmpty, audio.count <= Self.maximumSamples else {
                throw CoreMLParakeetJAError.inference("单个窗口必须在 0 到 15 秒之间")
            }

            let audioInput = try MLMultiArray(
                shape: [1, NSNumber(value: Self.maximumSamples)],
                dataType: .float32
            )
            let audioPointer = audioInput.dataPointer.bindMemory(
                to: Float.self,
                capacity: audioInput.count
            )
            audioPointer.initialize(repeating: 0, count: audioInput.count)
            audio.withUnsafeBufferPointer { source in
                guard let baseAddress = source.baseAddress else { return }
                audioPointer.update(from: baseAddress, count: source.count)
            }

            let audioLength = try Self.int32Array(shape: [1])
            audioLength.dataPointer.bindMemory(to: Int32.self, capacity: 1)[0] = Int32(audio.count)

            let preprocessorOutput = try preprocessor.prediction(
                from: try MLDictionaryFeatureProvider(dictionary: [
                    "audio_signal": MLFeatureValue(multiArray: audioInput),
                    "audio_length": MLFeatureValue(multiArray: audioLength),
                ])
            )
            let mel = try Self.array(
                named: "mel_features",
                from: preprocessorOutput,
                context: "Preprocessor"
            )
            let melLength = try Self.array(
                named: "mel_length",
                from: preprocessorOutput,
                context: "Preprocessor"
            )

            let encoderOutput = try encoder.prediction(
                from: try MLDictionaryFeatureProvider(dictionary: [
                    "mel_features": MLFeatureValue(multiArray: mel),
                    "mel_length": MLFeatureValue(multiArray: melLength),
                ])
            )
            let encoded = try Self.array(
                named: "encoder",
                from: encoderOutput,
                context: "Encoder"
            )
            let encodedLengthArray = try Self.array(
                named: "encoder_length",
                from: encoderOutput,
                context: "Encoder"
            )
            let encodedLength = min(
                encodedLengthArray[0].intValue,
                Self.encoderFrameCount(in: encoded)
            )
            guard encodedLength > 0 else { return [] }

            var state = try initialDecoderState()
            let encoderStep = try MLMultiArray(
                shape: [1, NSNumber(value: Self.encoderHiddenSize), 1],
                dataType: .float32
            )
            let audioDuration = Double(audio.count) / Double(Self.sampleRate)
            var timings: [ParakeetJATokenTiming] = []
            var frame = 0
            var lastEmissionFrame = -1
            var emissionsAtFrame = 0

            while frame < encodedLength, timings.count < Self.maximumTokensPerWindow {
                try Task.checkCancellation()
                try Self.copyEncoderFrame(
                    encoded,
                    frame: frame,
                    validFrameCount: encodedLength,
                    into: encoderStep
                )
                let decision = try runJoint(
                    encoderStep: encoderStep,
                    decoderStep: state.predictor
                )

                var duration = min(4, max(0, decision.duration))
                if decision.token == Self.blankTokenID {
                    frame += max(1, duration)
                    continue
                }
                guard decision.token >= 0, decision.token < vocabulary.count else {
                    throw CoreMLParakeetJAError.inference(
                        "Joint 返回越界 token：\(decision.token)"
                    )
                }

                if duration == 0, frame == lastEmissionFrame, emissionsAtFrame >= 1 {
                    duration = 1
                }

                let startTime = Double(frame) * Self.frameDuration
                let endTime = min(
                    audioDuration,
                    Double(frame + max(1, duration)) * Self.frameDuration
                )
                if startTime < audioDuration {
                    timings.append(
                        ParakeetJATokenTiming(
                            text: vocabulary[decision.token]
                                .replacingOccurrences(of: "▁", with: " "),
                            startTime: startTime,
                            endTime: min(
                                audioDuration,
                                max(startTime + Self.frameDuration, endTime)
                            ),
                            confidence: min(1, max(0, decision.probability))
                        )
                    )
                }

                state = try runDecoder(
                    token: decision.token,
                    hidden: state.hidden,
                    cell: state.cell
                )

                if frame == lastEmissionFrame {
                    emissionsAtFrame += 1
                } else {
                    lastEmissionFrame = frame
                    emissionsAtFrame = 1
                }
                frame += duration
                if emissionsAtFrame >= Self.maximumSymbolsPerFrame {
                    frame += 1
                    emissionsAtFrame = 0
                    lastEmissionFrame = -1
                }
            }
            return timings
        }

        private func initialDecoderState() throws -> DecoderState {
            let hidden = try MLMultiArray(
                shape: [
                    NSNumber(value: Self.decoderLayers),
                    1,
                    NSNumber(value: Self.decoderHiddenSize),
                ],
                dataType: .float32
            )
            let cell = try MLMultiArray(
                shape: hidden.shape,
                dataType: .float32
            )
            hidden.dataPointer.bindMemory(to: Float.self, capacity: hidden.count)
                .initialize(repeating: 0, count: hidden.count)
            cell.dataPointer.bindMemory(to: Float.self, capacity: cell.count)
                .initialize(repeating: 0, count: cell.count)
            return try runDecoder(
                token: Self.blankTokenID,
                hidden: hidden,
                cell: cell
            )
        }

        private func runDecoder(
            token: Int,
            hidden: MLMultiArray,
            cell: MLMultiArray
        ) throws -> DecoderState {
            let targets = try Self.int32Array(shape: [1, 1])
            targets.dataPointer.bindMemory(to: Int32.self, capacity: 1)[0] = Int32(token)
            let targetLength = try Self.int32Array(shape: [1])
            targetLength.dataPointer.bindMemory(to: Int32.self, capacity: 1)[0] = 1

            let output = try decoder.prediction(
                from: try MLDictionaryFeatureProvider(dictionary: [
                    "targets": MLFeatureValue(multiArray: targets),
                    "target_length": MLFeatureValue(multiArray: targetLength),
                    "h_in": MLFeatureValue(multiArray: hidden),
                    "c_in": MLFeatureValue(multiArray: cell),
                ])
            )
            return DecoderState(
                hidden: try Self.array(named: "h_out", from: output, context: "Decoder"),
                cell: try Self.array(named: "c_out", from: output, context: "Decoder"),
                predictor: try Self.array(named: "decoder", from: output, context: "Decoder")
            )
        }

        private func runJoint(
            encoderStep: MLMultiArray,
            decoderStep: MLMultiArray
        ) throws -> (token: Int, probability: Float, duration: Int) {
            let output = try joint.prediction(
                from: try MLDictionaryFeatureProvider(dictionary: [
                    "encoder_step": MLFeatureValue(multiArray: encoderStep),
                    "decoder_step": MLFeatureValue(multiArray: decoderStep),
                ])
            )
            let token = try Self.array(named: "token_id", from: output, context: "Joint")
            let probability = try Self.array(
                named: "token_prob",
                from: output,
                context: "Joint"
            )
            let duration = try Self.array(named: "duration", from: output, context: "Joint")
            return (
                token[0].intValue,
                probability[0].floatValue,
                duration[0].intValue
            )
        }

        // MARK: - Model and tensor helpers

        private static func loadModels(from directory: URL) throws -> ModelStack {
            let cpu = MLModelConfiguration()
            cpu.computeUnits = .cpuOnly
            let accelerator = MLModelConfiguration()
            accelerator.computeUnits = .cpuAndNeuralEngine

            do {
                return ModelStack(
                    preprocessor: try CoreMLModelLoader.load(
                        named: "Preprocessor",
                        from: directory,
                        configuration: cpu
                    ),
                    encoder: try CoreMLModelLoader.load(
                        named: "Encoder",
                        from: directory,
                        configuration: accelerator
                    ),
                    decoder: try CoreMLModelLoader.load(
                        named: "Decoderv2",
                        from: directory,
                        configuration: cpu
                    ),
                    joint: try CoreMLModelLoader.load(
                        named: "Jointerv2",
                        from: directory,
                        configuration: accelerator
                    )
                )
            } catch {
                #if os(macOS)
                    print(
                        "⚠️ Parakeet-JA: Neural Engine 模型加载失败，改用 CPU + GPU："
                            + error.localizedDescription
                    )
                    let fallback = MLModelConfiguration()
                    fallback.computeUnits = .cpuAndGPU
                    return ModelStack(
                        preprocessor: try CoreMLModelLoader.load(
                            named: "Preprocessor",
                            from: directory,
                            configuration: cpu
                        ),
                        encoder: try CoreMLModelLoader.load(
                            named: "Encoder",
                            from: directory,
                            configuration: fallback
                        ),
                        decoder: try CoreMLModelLoader.load(
                            named: "Decoderv2",
                            from: directory,
                            configuration: cpu
                        ),
                        joint: try CoreMLModelLoader.load(
                            named: "Jointerv2",
                            from: directory,
                            configuration: fallback
                        )
                    )
                #else
                    throw CoreMLParakeetJAError.model(error.localizedDescription)
                #endif
            }
        }

        private static func windowStarts(sampleCount: Int) -> [Int] {
            guard sampleCount > maximumSamples else { return [0] }
            var starts: [Int] = []
            var start = 0
            while start < sampleCount {
                starts.append(start)
                if start + maximumSamples >= sampleCount { break }
                start += windowStride
            }
            return starts
        }

        private static func encoderFrameCount(in array: MLMultiArray) -> Int {
            let shape = array.shape.map(\.intValue)
            guard shape.count == 3 else { return 0 }
            if shape[1] == encoderHiddenSize { return shape[2] }
            if shape[2] == encoderHiddenSize { return shape[1] }
            return 0
        }

        private static func copyEncoderFrame(
            _ source: MLMultiArray,
            frame: Int,
            validFrameCount: Int,
            into destination: MLMultiArray
        ) throws {
            let shape = source.shape.map(\.intValue)
            let strides = source.strides.map(\.intValue)
            guard source.dataType == .float32,
                shape.count == 3,
                shape[0] == 1,
                frame >= 0,
                frame < validFrameCount
            else {
                throw CoreMLParakeetJAError.inference(
                    "Encoder 输出布局无效：\(shape)"
                )
            }

            let hiddenAxis: Int
            let timeAxis: Int
            if shape[1] == encoderHiddenSize {
                hiddenAxis = 1
                timeAxis = 2
            } else if shape[2] == encoderHiddenSize {
                hiddenAxis = 2
                timeAxis = 1
            } else {
                throw CoreMLParakeetJAError.inference(
                    "Encoder hidden size 不匹配：\(shape)"
                )
            }

            let sourcePointer = source.dataPointer.bindMemory(
                to: Float.self,
                capacity: source.count
            )
            let destinationPointer = destination.dataPointer.bindMemory(
                to: Float.self,
                capacity: destination.count
            )
            let frameOffset = frame * strides[timeAxis]
            for hidden in 0..<encoderHiddenSize {
                destinationPointer[hidden] =
                    sourcePointer[frameOffset + hidden * strides[hiddenAxis]]
            }
        }

        private static func int32Array(shape: [NSNumber]) throws -> MLMultiArray {
            try MLMultiArray(shape: shape, dataType: .int32)
        }

        private static func array(
            named name: String,
            from provider: MLFeatureProvider,
            context: String
        ) throws -> MLMultiArray {
            guard let value = provider.featureValue(for: name)?.multiArrayValue else {
                throw CoreMLParakeetJAError.inference(
                    "\(context) 缺少输出 \(name)"
                )
            }
            return value
        }

        private static func normalizedText(from pieces: [String]) -> String {
            var result = pieces.joined()
            while result.contains("  ") {
                result = result.replacingOccurrences(of: "  ", with: " ")
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Removes a repeated token sequence introduced by the 2-second overlap.
        ///
        /// Timestamp midpoint ownership handles the common case. This additional
        /// sequence check covers small timing drift where the previous window emits
        /// a prefix and the next window emits the complete Japanese word.
        private static func duplicateTokenPrefixLength(
            existing: [ParakeetJATokenTiming],
            incoming: [ParakeetJATokenTiming]
        ) -> Int {
            let limit = min(24, existing.count, incoming.count)
            guard limit > 0 else { return 0 }

            for count in stride(from: limit, through: 1, by: -1) {
                let left = existing.suffix(count).map {
                    $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let right = incoming.prefix(count).map {
                    $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if left == right, left.contains(where: { !$0.isEmpty }) {
                    return count
                }
            }
            return 0
        }
    }
#endif
