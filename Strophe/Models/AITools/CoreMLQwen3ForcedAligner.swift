#if STROPHE_LOCAL_AI
import CoreML
import Foundation

nonisolated struct Qwen3AlignedWord: Sendable {
    let text: String
    let start: Double
    let end: Double
}

@available(macOS 15.0, iOS 18.0, *)
nonisolated final class CoreMLQwen3ForcedAligner: @unchecked Sendable {
    private let audioEncoder: MLModel
    private let embedding: MLModel
    private let textDecoder: MLModel
    private let tokenizer: Qwen3BPETokenizer
    private let features = Qwen3WhisperFeatureExtractor()
    private let hiddenSize: Int
    private let classCount: Int
    private let timestampStep: Double

    init(directory: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        audioEncoder = try CoreMLModelLoader.load(named: "audio_encoder", from: directory, configuration: configuration)
        embedding = try CoreMLModelLoader.load(named: "embedding", from: directory, configuration: configuration)
        textDecoder = try CoreMLModelLoader.load(named: "text_decoder", from: directory, configuration: configuration)
        tokenizer = try Qwen3BPETokenizer(directory: directory)
        let config = try Self.readConfig(directory)
        hiddenSize = config["hidden_size"] as? Int ?? 1024
        classCount = config["classify_num"] as? Int ?? 5000
        timestampStep = config["timestamp_segment_time"] as? Double ?? 0.08
    }

    func align(audio: [Float], text: String, language: String) throws -> [Qwen3AlignedWord] {
        let mel = features.process(audio)
        guard mel.frames > 0, mel.frames <= 3000 else {
            throw CoreMLQwen3Error.inference("ForcedAligner 音频分块必须在 30 秒以内")
        }
        let (audioEmbeddings, audioTokenCount) = try encodeAudio(mel)
        let slotted = Qwen3AlignmentTextProcessor.prepare(text, tokenizer: tokenizer, language: language)
        guard !slotted.words.isEmpty else { return [] }

        var ids = [Qwen3CoreMLTokens.audioStart]
        let audioOffset = ids.count
        ids.append(contentsOf: repeatElement(Qwen3CoreMLTokens.audioPad, count: audioTokenCount))
        ids.append(Qwen3CoreMLTokens.audioEnd)
        let slottedOffset = ids.count
        ids.append(contentsOf: slotted.tokenIDs)

        var decoderSeq = 768
        if let desc = textDecoder.modelDescription.inputDescriptionsByName["inputs_embeds"],
           let constraint = desc.multiArrayConstraint {
            if constraint.shapeConstraint.type == .enumerated {
                let shapes = constraint.shapeConstraint.enumeratedShapes
                if shapes.count == 1 {
                    decoderSeq = shapes[0][1].intValue
                } else {
                    let allowed = shapes.map { $0[1].intValue }.sorted()
                    if let val = allowed.first(where: { $0 >= ids.count }) {
                        decoderSeq = val
                    } else {
                        throw CoreMLQwen3Error.inference("ForcedAligner token 数量 \(ids.count) 超过模型上限 \(allowed.last ?? 0)")
                    }
                }
            }
        }

        guard ids.count <= decoderSeq else {
            throw CoreMLQwen3Error.inference("ForcedAligner token 数量 \(ids.count) 超过模型 decoder 上限 \(decoderSeq)")
        }

        let allowedEmbeddingSeqs = [10, 20, 50, 100, 200, 500, 1000, 2000]
        guard let embeddingSeq = allowedEmbeddingSeqs.first(where: { $0 >= decoderSeq }) else {
            throw CoreMLQwen3Error.inference("ForcedAligner 无法匹配 embedding sequence 长度 \(decoderSeq)")
        }

        var embeddingIds = ids
        embeddingIds.append(contentsOf: repeatElement(0, count: embeddingSeq - embeddingIds.count))
        let tokenEmbeddings = try embed(embeddingIds)

        guard tokenEmbeddings.shape.count == 3, tokenEmbeddings.shape[2].intValue == hiddenSize else {
            throw CoreMLQwen3Error.inference("ForcedAligner embedding shape 不匹配")
        }

        let inputs = try MLMultiArray(shape: [1, decoderSeq as NSNumber, hiddenSize as NSNumber], dataType: .float32)
        let inputsPtr = inputs.dataPointer.assumingMemoryBound(to: Float.self)
        let tokenRowStride = tokenEmbeddings.strides[1].intValue
        let tokenColStride = tokenEmbeddings.strides[2].intValue
        for r in 0..<decoderSeq {
            for c in 0..<hiddenSize {
                inputsPtr[r * hiddenSize + c] = CoreMLQwen3ASR.floatValue(tokenEmbeddings, r * tokenRowStride + c * tokenColStride)
            }
        }

        try splice(audioEmbeddings, into: inputs, destinationOffset: audioOffset, count: audioTokenCount)

        let output = try textDecoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "inputs_embeds": MLFeatureValue(multiArray: inputs)
        ]))
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw CoreMLQwen3Error.inference("ForcedAligner logits 输出缺失")
        }
        let positions = slotted.timestampPositions.map { $0 + slottedOffset }
        let raw = positions.map { argmax(logits, row: $0) }
        let corrected = Qwen3TimestampCorrection.monotonic(raw)
        var words: [Qwen3AlignedWord] = []
        for index in slotted.words.indices where index * 2 + 1 < corrected.count {
            let duration = Double(audio.count) / 16_000
            let start = min(Double(corrected[index * 2]) * timestampStep, duration)
            let end = min(max(start, Double(corrected[index * 2 + 1]) * timestampStep), duration)
            words.append(Qwen3AlignedWord(text: slotted.words[index], start: start, end: end))
        }
        return words
    }
    private func encodeAudio(_ mel: Qwen3MelFeatures) throws -> (embeddings: MLMultiArray, count: Int) {
        let inputName = audioEncoder.modelDescription.inputDescriptionsByName.keys.contains("mel") ? "mel" : "mel_features"
        let hasMelLength = audioEncoder.modelDescription.inputDescriptionsByName.keys.contains("mel_length")

        var targetFrames = 3000
        if let desc = audioEncoder.modelDescription.inputDescriptionsByName[inputName],
           let constraint = desc.multiArrayConstraint {
            let shape = constraint.shape
            if shape.count >= 3 {
                let defaultFrames = shape[2].intValue
                if constraint.shapeConstraint.type == .enumerated {
                    let allowed = constraint.shapeConstraint.enumeratedShapes.map { $0[2].intValue }.sorted()
                    if let val = allowed.first(where: { $0 >= mel.frames }) {
                        targetFrames = val
                    } else {
                        targetFrames = defaultFrames
                    }
                } else if constraint.shapeConstraint.type == .range {
                    targetFrames = defaultFrames
                } else {
                    targetFrames = defaultFrames
                }
            }
        }

        guard mel.frames <= targetFrames else {
            throw CoreMLQwen3Error.inference("ForcedAligner mel 帧数 \(mel.frames) 超过模型上限 \(targetFrames)")
        }

        let input = try MLMultiArray(shape: [1, mel.melBins as NSNumber, targetFrames as NSNumber], dataType: .float32)
        let pointer = input.dataPointer.assumingMemoryBound(to: Float.self)
        pointer.initialize(repeating: 0, count: input.count)
        for bin in 0..<mel.melBins {
            for frame in 0..<mel.frames {
                pointer[bin * targetFrames + frame] = mel.values[bin * mel.frames + frame]
            }
        }

        var dictionary: [String: MLFeatureValue] = [inputName: MLFeatureValue(multiArray: input)]
        if hasMelLength {
            let length = try MLMultiArray(shape: [1], dataType: .int32)
            length[0] = NSNumber(value: Int32(mel.frames))
            dictionary["mel_length"] = MLFeatureValue(multiArray: length)
        }

        let output = try audioEncoder.prediction(from: MLDictionaryFeatureProvider(dictionary: dictionary))
        guard let value = output.featureValue(for: "audio_embeddings")?.multiArrayValue else {
            throw CoreMLQwen3Error.inference("ForcedAligner audio encoder 输出缺失")
        }

        let count: Int
        if let outputLength = output.featureValue(for: "output_length")?.multiArrayValue {
            count = max(0, outputLength[0].intValue)
        } else {
            count = value.shape.count > 1 ? value.shape[1].intValue : 0
        }
        return (value, count)
    }

    private func embed(_ ids: [Int]) throws -> MLMultiArray {
        let input = try MLMultiArray(shape: [1, ids.count as NSNumber], dataType: .int32)
        for (index, id) in ids.enumerated() { input[index] = NSNumber(value: Int32(id)) }
        let output = try embedding.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: input)
        ]))
        guard let value = output.featureValue(for: "embeddings")?.multiArrayValue else {
            throw CoreMLQwen3Error.inference("ForcedAligner token embedding 输出缺失")
        }
        return value
    }

    private func float32Copy(_ source: MLMultiArray) throws -> MLMultiArray {
        let result = try MLMultiArray(shape: source.shape, dataType: .float32)
        let output = result.dataPointer.assumingMemoryBound(to: Float.self)
        let rows = source.shape[1].intValue
        for row in 0..<rows {
            CoreMLQwen3ASR.copyRowForAligner(source, row: row, into: output, destinationRow: row, width: hiddenSize)
        }
        return result
    }

    private func splice(_ source: MLMultiArray, into destination: MLMultiArray, destinationOffset: Int, count: Int) throws {
        guard destinationOffset + count <= destination.shape[1].intValue else {
            throw CoreMLQwen3Error.inference("ForcedAligner audio embedding 越界")
        }
        let output = destination.dataPointer.assumingMemoryBound(to: Float.self)
        for row in 0..<count {
            CoreMLQwen3ASR.copyRowForAligner(source, row: row, into: output, destinationRow: destinationOffset + row, width: hiddenSize)
        }
    }

    private func argmax(_ logits: MLMultiArray, row: Int) -> Int {
        let rowStride = logits.strides.count >= 2 ? logits.strides[logits.strides.count - 2].intValue : classCount
        let scalarStride = logits.strides.last?.intValue ?? 1
        var best = -Float.infinity, bestIndex = 0
        for index in 0..<classCount {
            let value = CoreMLQwen3ASR.floatValue(logits, row * rowStride + index * scalarStride)
            if value.isFinite && value > best { best = value; bestIndex = index }
        }
        return bestIndex
    }

    private static func readConfig(_ directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

@available(macOS 15.0, iOS 18.0, *)
nonisolated private extension CoreMLQwen3ASR {
    static func copyRowForAligner(_ source: MLMultiArray, row: Int, into destination: UnsafeMutablePointer<Float>, destinationRow: Int, width: Int) {
        let rowStride = source.strides.count >= 2 ? source.strides[source.strides.count - 2].intValue : width
        let scalarStride = source.strides.last?.intValue ?? 1
        for column in 0..<width { destination[destinationRow * width + column] = floatValue(source, row * rowStride + column * scalarStride) }
    }
}
#endif
