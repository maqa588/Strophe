#if STROPHE_LOCAL_AI
import CoreML
import Foundation

@available(macOS 15.0, iOS 18.0, *)
nonisolated final class CoreMLQwen3ASR: @unchecked Sendable {
    private let encoder: MLModel
    private let embedding: MLModel
    private let decoderPart1: MLModel
    private let decoderPart2: MLModel
    private let tokenizer: Qwen3BPETokenizer
    private let features = Qwen3WhisperFeatureExtractor()
    private let maxSequenceLength: Int
    private let hiddenSize: Int
    private let batchSize: Int
    private var part1State: MLState
    private var part2State: MLState
    private var position = 0

    init(directory: URL) throws {
        let config = try Self.readConfig(directory)
        maxSequenceLength = config["max_seq_length"] as? Int ?? 1024
        hiddenSize = config["hidden_size"] as? Int ?? 1024
        batchSize = (config["enumerated_t"] as? [Int])?.first ?? 128

        let encoderConfiguration = MLModelConfiguration()
        encoderConfiguration.computeUnits = .all
        let decoderConfiguration = MLModelConfiguration()
        decoderConfiguration.computeUnits = .cpuAndNeuralEngine
        encoder = try MLModel(contentsOf: try Self.modelURL("encoder", directory), configuration: encoderConfiguration)
        embedding = try MLModel(contentsOf: try Self.modelURL("embedding", directory), configuration: decoderConfiguration)
        decoderPart1 = try MLModel(contentsOf: try Self.modelURL("decoder_part1", directory), configuration: decoderConfiguration)
        decoderPart2 = try MLModel(contentsOf: try Self.modelURL("decoder_part2", directory), configuration: decoderConfiguration)
        tokenizer = try Qwen3BPETokenizer(directory: directory)
        part1State = decoderPart1.makeState()
        part2State = decoderPart2.makeState()
    }

    func transcribe(audio: [Float], language: String?, maxTokens: Int = 448) throws -> String {
        let mel = features.process(audio)
        guard mel.frames > 0, mel.frames <= 3000 else {
            throw CoreMLQwen3Error.inference("ASR 音频分块必须在 30 秒以内")
        }
        let encoded = try encode(mel)
        reset()

        let prefix = [Qwen3CoreMLTokens.imStart, Qwen3CoreMLTokens.system, Qwen3CoreMLTokens.newline,
                      Qwen3CoreMLTokens.imEnd, Qwen3CoreMLTokens.newline, Qwen3CoreMLTokens.imStart,
                      Qwen3CoreMLTokens.user, Qwen3CoreMLTokens.newline, Qwen3CoreMLTokens.audioStart]
        var suffix = [Qwen3CoreMLTokens.audioEnd, Qwen3CoreMLTokens.imEnd, Qwen3CoreMLTokens.newline,
                      Qwen3CoreMLTokens.imStart, Qwen3CoreMLTokens.assistant, Qwen3CoreMLTokens.newline]
        if let language, language != "auto" { suffix.append(contentsOf: tokenizer.encode("language \(language)")) }
        suffix.append(Qwen3CoreMLTokens.asrText)

        var logits = try prefill(tokens: prefix)
        var consumed = 0
        while consumed < encoded.count {
            let count = min(batchSize, encoded.count - consumed)
            logits = try prefill(embeddings: encoded.embeddings, offset: consumed, count: count)
            consumed += count
        }
        logits = try prefill(tokens: suffix)

        var generated: [Int] = []
        var next = argmax(logits, skipping: Qwen3CoreMLTokens.imEnd)
        generated.append(next)
        for _ in 1..<maxTokens {
            if next == Qwen3CoreMLTokens.imEnd { break }
            logits = try step(try tokenEmbedding(next))
            next = argmax(logits)
            if next == Qwen3CoreMLTokens.imEnd { break }
            generated.append(next)
        }
        return tokenizer.decode(generated).replacingOccurrences(of: "<asr_text>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func encode(_ mel: Qwen3MelFeatures) throws -> (embeddings: MLMultiArray, count: Int) {
        let paddedFrames = 3000
        let input = try MLMultiArray(shape: [1, mel.melBins as NSNumber, paddedFrames as NSNumber], dataType: .float32)
        let pointer = input.dataPointer.assumingMemoryBound(to: Float.self)
        pointer.initialize(repeating: 0, count: input.count)
        for bin in 0..<mel.melBins {
            for frame in 0..<mel.frames { pointer[bin * paddedFrames + frame] = mel.values[bin * mel.frames + frame] }
        }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: Int32(mel.frames))
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: input), "mel_length": MLFeatureValue(multiArray: length)
        ])
        let output = try encoder.prediction(from: provider)
        guard let embeddings = output.featureValue(for: "audio_embeddings")?.multiArrayValue,
              let outputLength = output.featureValue(for: "output_length")?.multiArrayValue else {
            throw CoreMLQwen3Error.inference("ASR encoder 输出缺失")
        }
        return (embeddings, max(0, outputLength[0].intValue))
    }

    private func reset() {
        position = 0
        part1State = decoderPart1.makeState()
        part2State = decoderPart2.makeState()
    }

    private func tokenEmbedding(_ token: Int) throws -> MLMultiArray {
        let ids = try MLMultiArray(shape: [1, 1], dataType: .int32)
        ids[0] = NSNumber(value: Int32(token))
        let output = try embedding.prediction(from: MLDictionaryFeatureProvider(dictionary: ["token_id": MLFeatureValue(multiArray: ids)]))
        guard let value = output.featureValue(for: "embedding")?.multiArrayValue else {
            throw CoreMLQwen3Error.inference("ASR embedding 输出缺失")
        }
        return value
    }

    private func prefill(tokens: [Int]) throws -> MLMultiArray {
        var result: MLMultiArray?
        var offset = 0
        while offset < tokens.count {
            let count = min(batchSize, tokens.count - offset)
            let packed = try MLMultiArray(shape: [1, count as NSNumber, hiddenSize as NSNumber], dataType: .float32)
            let destination = packed.dataPointer.assumingMemoryBound(to: Float.self)
            for index in 0..<count { Self.copyRow(try tokenEmbedding(tokens[offset + index]), row: 0, into: destination, destinationRow: index, width: hiddenSize) }
            result = try prefill(embeddings: packed, offset: 0, count: count)
            offset += count
        }
        guard let result else { throw CoreMLQwen3Error.inference("空的 ASR prompt") }
        return result
    }

    private func step(_ embedding: MLMultiArray) throws -> MLMultiArray {
        try dispatch(count: 1) { firstSlot, pointer in
            Self.copyRow(embedding, row: 0, into: pointer, destinationRow: firstSlot, width: self.hiddenSize)
        }
    }

    private func prefill(embeddings: MLMultiArray, offset: Int, count: Int) throws -> MLMultiArray {
        try dispatch(count: count) { firstSlot, pointer in
            for index in 0..<count {
                Self.copyRow(embeddings, row: offset + index, into: pointer, destinationRow: firstSlot + index, width: self.hiddenSize)
            }
        }
    }

    private func dispatch(count: Int, fill: (Int, UnsafeMutablePointer<Float>) -> Void) throws -> MLMultiArray {
        let scratchStart = maxSequenceLength - (batchSize - 1)
        guard count > 0, count <= batchSize, position + count <= scratchStart else {
            throw CoreMLQwen3Error.inference("ASR KV cache 已满")
        }
        let first = batchSize - count
        let embeds = try MLMultiArray(shape: [1, batchSize as NSNumber, hiddenSize as NSNumber], dataType: .float32)
        let embedPointer = embeds.dataPointer.assumingMemoryBound(to: Float.self)
        embedPointer.initialize(repeating: 0, count: embeds.count)
        fill(first, embedPointer)
        let positions = try MLMultiArray(shape: [batchSize as NSNumber], dataType: .int32)
        for index in 0..<first { positions[index] = NSNumber(value: Int32(scratchStart + index)) }
        for index in 0..<count { positions[first + index] = NSNumber(value: Int32(position + index)) }
        let mask = try MLMultiArray(shape: [1, 1, batchSize as NSNumber, maxSequenceLength as NSNumber], dataType: .float32)
        let maskPointer = mask.dataPointer.assumingMemoryBound(to: Float.self)
        for row in 0..<batchSize {
            let realPosition = row >= first ? position + row - first : -1
            for column in 0..<maxSequenceLength {
                maskPointer[row * maxSequenceLength + column] = realPosition >= 0 && column <= realPosition && column < scratchStart ? 0 : -1e4
            }
        }
        position += count
        let inputs: [String: MLFeatureValue] = [
            "input_embeds": MLFeatureValue(multiArray: embeds), "positions": MLFeatureValue(multiArray: positions),
            "attention_mask": MLFeatureValue(multiArray: mask)
        ]
        let firstOutput = try decoderPart1.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs), using: part1State)
        guard let hidden = firstOutput.featureValue(for: "hidden_state")?.multiArrayValue else {
            throw CoreMLQwen3Error.inference("decoder_part1 输出缺失")
        }
        var secondInputs = inputs
        secondInputs["input_embeds"] = MLFeatureValue(multiArray: hidden)
        let secondOutput = try decoderPart2.prediction(from: MLDictionaryFeatureProvider(dictionary: secondInputs), using: part2State)
        guard let logits = secondOutput.featureValue(for: "logits")?.multiArrayValue else {
            throw CoreMLQwen3Error.inference("decoder_part2 输出缺失")
        }
        return logits
    }

    private func argmax(_ logits: MLMultiArray, skipping: Int? = nil) -> Int {
        let count = logits.shape.last?.intValue ?? logits.count
        let stride = logits.strides.last?.intValue ?? 1
        var best = -Float.infinity, bestIndex = 0
        for index in 0..<count where index != skipping {
            let value = Self.floatValue(logits, index * stride)
            if value.isFinite && value > best { best = value; bestIndex = index }
        }
        return bestIndex
    }

    private static func copyRow(_ source: MLMultiArray, row: Int, into destination: UnsafeMutablePointer<Float>, destinationRow: Int, width: Int) {
        let rowStride = source.strides.count >= 2 ? source.strides[source.strides.count - 2].intValue : width
        let scalarStride = source.strides.last?.intValue ?? 1
        for column in 0..<width { destination[destinationRow * width + column] = floatValue(source, row * rowStride + column * scalarStride) }
    }

    static func floatValue(_ array: MLMultiArray, _ index: Int) -> Float {
        switch array.dataType {
        case .float32: return array.dataPointer.assumingMemoryBound(to: Float.self)[index]
        case .float16: return halfToFloat(array.dataPointer.assumingMemoryBound(to: UInt16.self)[index])
        default: return array[index].floatValue
        }
    }

    private static func halfToFloat(_ half: UInt16) -> Float {
        let sign = UInt32(half & 0x8000) << 16
        let halfExponent = UInt32(half & 0x7C00) >> 10
        var fraction = UInt32(half & 0x03FF)
        if halfExponent == 0 {
            if fraction == 0 { return Float(bitPattern: sign) }
            var unbiasedExponent = -14
            while fraction & 0x0400 == 0 { fraction <<= 1; unbiasedExponent -= 1 }
            fraction &= 0x03FF
            let exponent = UInt32(unbiasedExponent + 127)
            return Float(bitPattern: sign | (exponent << 23) | (fraction << 13))
        } else if halfExponent == 31 {
            return Float(bitPattern: sign | 0x7F800000 | (fraction << 13))
        }
        let exponent = halfExponent + (127 - 15)
        return Float(bitPattern: sign | (exponent << 23) | (fraction << 13))
    }

    private static func modelURL(_ name: String, _ directory: URL) throws -> URL {
        let compiled = directory.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        guard FileManager.default.fileExists(atPath: compiled.path) else { throw CoreMLQwen3Error.model("缺少 \(name).mlmodelc") }
        return compiled
    }

    private static func readConfig(_ directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
#endif
