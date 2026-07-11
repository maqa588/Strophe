#if STROPHE_LOCAL_AI
import Accelerate
import Foundation
import NaturalLanguage

// CoreML Qwen3 protocol code adapted from soniqo/speech-swift (Apache-2.0).

nonisolated enum CoreMLQwen3Error: LocalizedError {
    case model(String)
    case inference(String)
    case tokenizer(String)

    var errorDescription: String? {
        switch self {
        case .model(let message): return "CoreML 模型加载失败：\(message)"
        case .inference(let message): return "CoreML 推理失败：\(message)"
        case .tokenizer(let message): return "Tokenizer 加载失败：\(message)"
        }
    }
}

nonisolated enum Qwen3CoreMLTokens {
    static let audioPad = 151676
    static let audioStart = 151669
    static let audioEnd = 151670
    static let imStart = 151644
    static let imEnd = 151645
    static let timestamp = 151705
    static let asrText = 151704
    static let newline = 198
    static let system = 8948
    static let user = 872
    static let assistant = 77091
}

nonisolated final class Qwen3BPETokenizer: @unchecked Sendable {
    private var idToToken: [Int: String] = [:]
    private var tokenToID: [String: Int] = [:]
    private var mergeRanks: [String: Int] = [:]

    init(directory: URL) throws {
        let vocabURL = directory.appendingPathComponent("vocab.json")
        let data = try Data(contentsOf: vocabURL)
        guard let vocab = try JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            throw CoreMLQwen3Error.tokenizer("vocab.json 格式错误")
        }
        tokenToID = vocab
        idToToken = Dictionary(uniqueKeysWithValues: vocab.map { ($0.value, $0.key) })

        let configURL = directory.appendingPathComponent("tokenizer_config.json")
        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let added = config["added_tokens_decoder"] as? [String: [String: Any]] {
            for (key, value) in added {
                guard let id = Int(key), let token = value["content"] as? String else { continue }
                idToToken[id] = token
                tokenToID[token] = id
            }
        }

        let mergesURL = directory.appendingPathComponent("merges.txt")
        let merges = try String(contentsOf: mergesURL, encoding: .utf8)
        for (rank, line) in merges.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            if line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ")
            if parts.count == 2 { mergeRanks["\(parts[0]) \(parts[1])"] = rank }
        }
    }

    func encode(_ text: String) -> [Int] {
        preTokenize(text).flatMap { word in
            bpe(word).compactMap { tokenToID[$0] }
        }
    }

    func decode(_ ids: [Int]) -> String {
        var bytes: [UInt8] = []
        for id in ids {
            guard let token = idToToken[id] else { continue }
            if token.hasPrefix("<|") && token.hasSuffix("|>") { continue }
            if token.hasPrefix("<") && token.hasSuffix(">") && !token.contains("|") {
                bytes.append(contentsOf: token.utf8)
                continue
            }
            for character in token {
                if let byte = Self.unicodeToByte[character] { bytes.append(byte) }
                else { bytes.append(contentsOf: String(character).utf8) }
            }
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func preTokenize(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text {
            if character == " " || character == "\n" || character == "\t" {
                if !current.isEmpty { words.append(byteEncode(current)); current = "" }
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(byteEncode(current)) }
        return words
    }

    private func byteEncode(_ text: String) -> String {
        String(text.utf8.compactMap { Self.byteToUnicode[$0] })
    }

    private func bpe(_ word: String) -> [String] {
        var pieces = word.map(String.init)
        while pieces.count > 1 {
            var bestIndex: Int?
            var bestRank = Int.max
            for index in 0..<(pieces.count - 1) {
                if let rank = mergeRanks["\(pieces[index]) \(pieces[index + 1])"], rank < bestRank {
                    bestRank = rank
                    bestIndex = index
                }
            }
            guard let index = bestIndex else { break }
            pieces[index] += pieces[index + 1]
            pieces.remove(at: index + 1)
        }
        return pieces
    }

    private static let byteToUnicode: [UInt8: Character] = {
        var result: [UInt8: Character] = [:]
        var extra = 0
        let direct = Array(UInt8(ascii: "!")...UInt8(ascii: "~"))
            + Array(UInt8(0xA1)...UInt8(0xAC)) + Array(UInt8(0xAE)...UInt8(0xFF))
        for byte in direct { result[byte] = Character(UnicodeScalar(byte)) }
        for byte in UInt8.min...UInt8.max where result[byte] == nil {
            result[byte] = Character(UnicodeScalar(0x100 + extra)!)
            extra += 1
        }
        return result
    }()

    private static let unicodeToByte = Dictionary(uniqueKeysWithValues: byteToUnicode.map { ($0.value, $0.key) })
}

nonisolated struct Qwen3MelFeatures: Sendable {
    let values: [Float] // [melBins, frames]
    let melBins: Int
    let frames: Int
}

nonisolated final class Qwen3WhisperFeatureExtractor: @unchecked Sendable {
    let sampleRate = 16_000
    let fftSize = 400
    let paddedFFT = 512
    let hopLength = 160
    let melBins = 128
    private let window: [Float]
    private let filterbank: [Float] // [melBins, fftBins]
    private let fftSetup: FFTSetup

    init() {
        window = (0..<400).map { 0.5 * (1 - cos(2 * Float.pi * Float($0) / 400)) }
        guard let setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2)) else {
            fatalError("Unable to create FFT setup")
        }
        fftSetup = setup
        filterbank = Self.makeFilterbank(sampleRate: 16_000, fftSize: 512, melBins: 128)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    func process(_ audio: [Float]) -> Qwen3MelFeatures {
        guard !audio.isEmpty else { return Qwen3MelFeatures(values: [], melBins: melBins, frames: 0) }
        let pad = fftSize / 2
        var padded = [Float](repeating: 0, count: audio.count + 2 * pad)
        for index in 0..<pad { padded[index] = audio[min(max(pad - index, 0), audio.count - 1)] }
        padded.replaceSubrange(pad..<(pad + audio.count), with: audio)
        for index in 0..<pad { padded[pad + audio.count + index] = audio[max(0, audio.count - 2 - index)] }

        let frameCount = max(1, (padded.count - fftSize) / hopLength + 1)
        let binCount = paddedFFT / 2 + 1
        var power = [Float](repeating: 0, count: frameCount * binCount)
        var real = [Float](repeating: 0, count: paddedFFT / 2)
        var imag = [Float](repeating: 0, count: paddedFFT / 2)
        var frame = [Float](repeating: 0, count: paddedFFT)

        for frameIndex in 0..<frameCount {
            let start = frameIndex * hopLength
            padded.withUnsafeBufferPointer { source in
                vDSP_vmul(source.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(fftSize))
            }
            frame.replaceSubrange(fftSize..<paddedFFT, with: repeatElement(0, count: paddedFFT - fftSize))
            for index in 0..<(paddedFFT / 2) { real[index] = frame[index * 2]; imag[index] = frame[index * 2 + 1] }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imag.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &split, 1, 9, FFTDirection(kFFTDirection_Forward))
                }
            }
            let base = frameIndex * binCount
            power[base] = real[0] * real[0]
            power[base + paddedFFT / 2] = imag[0] * imag[0]
            for bin in 1..<(paddedFFT / 2) { power[base + bin] = real[bin] * real[bin] + imag[bin] * imag[bin] }
        }

        var filterbankT = [Float](repeating: 0, count: binCount * melBins)
        vDSP_mtrans(filterbank, 1, &filterbankT, 1, vDSP_Length(binCount), vDSP_Length(melBins))
        var mel = [Float](repeating: 0, count: frameCount * melBins)
        vDSP_mmul(power, 1, filterbankT, 1, &mel, 1, vDSP_Length(frameCount), vDSP_Length(melBins), vDSP_Length(binCount))
        var floor: Float = 1e-10
        var ceiling = Float.greatestFiniteMagnitude
        vDSP_vclip(mel, 1, &floor, &ceiling, &mel, 1, vDSP_Length(mel.count))
        var count = Int32(mel.count)
        vvlog10f(&mel, mel, &count)
        var maximum: Float = 0
        vDSP_maxv(mel, 1, &maximum, vDSP_Length(mel.count))
        floor = maximum - 8
        vDSP_vclip(mel, 1, &floor, &ceiling, &mel, 1, vDSP_Length(mel.count))
        var scale: Float = 0.25
        var offset: Float = 1
        vDSP_vsmsa(mel, 1, &scale, &offset, &mel, 1, vDSP_Length(mel.count))

        let frames = max(0, frameCount - 1)
        var transposed = [Float](repeating: 0, count: frames * melBins)
        for time in 0..<frames { for melIndex in 0..<melBins { transposed[melIndex * frames + time] = mel[time * melBins + melIndex] } }
        return Qwen3MelFeatures(values: transposed, melBins: melBins, frames: frames)
    }

    private static func makeFilterbank(sampleRate: Int, fftSize: Int, melBins: Int) -> [Float] {
        func hzToMel(_ hz: Float) -> Float { hz < 1000 ? 3 * hz / 200 : 15 + log(hz / 1000) * (27 / log(6.4)) }
        func melToHz(_ mel: Float) -> Float { mel < 15 ? 200 * mel / 3 : 1000 * exp((mel - 15) * (log(6.4) / 27)) }
        let bins = fftSize / 2 + 1
        let low = hzToMel(0), high = hzToMel(Float(sampleRate) / 2)
        let frequencies = (0..<(melBins + 2)).map { melToHz(low + Float($0) * (high - low) / Float(melBins + 1)) }
        var result = [Float](repeating: 0, count: melBins * bins)
        for mel in 0..<melBins {
            let normalization = 2 / (frequencies[mel + 2] - frequencies[mel])
            for bin in 0..<bins {
                let hz = Float(bin * sampleRate) / Float(fftSize)
                let rising = (hz - frequencies[mel]) / (frequencies[mel + 1] - frequencies[mel])
                let falling = (frequencies[mel + 2] - hz) / (frequencies[mel + 2] - frequencies[mel + 1])
                result[mel * bins + bin] = max(0, min(rising, falling)) * normalization
            }
        }
        return result
    }
}

nonisolated struct Qwen3SlottedText: Sendable {
    let tokenIDs: [Int]
    let timestampPositions: [Int]
    let words: [String]
}

nonisolated enum Qwen3AlignmentTextProcessor {
    static func prepare(_ text: String, tokenizer: Qwen3BPETokenizer, language: String) -> Qwen3SlottedText {
        let words = split(text, language: language)
        var ids: [Int] = [], positions: [Int] = [], accepted: [String] = []
        for surface in words {
            let cleaned = String(surface.unicodeScalars.filter {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "'"
            })
            let wordIDs = tokenizer.encode(cleaned)
            guard !wordIDs.isEmpty else { continue }
            ids.append(contentsOf: wordIDs)
            positions.append(ids.count); ids.append(Qwen3CoreMLTokens.timestamp)
            positions.append(ids.count); ids.append(Qwen3CoreMLTokens.timestamp)
            accepted.append(surface)
        }
        return Qwen3SlottedText(tokenIDs: ids, timestampPositions: positions, words: accepted)
    }

    private static func split(_ text: String, language: String) -> [String] {
        let code = language.lowercased()
        if code == "ja" || code == "japanese" || code == "ko" || code == "korean" || code == "th" || code == "thai" {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            if code == "ja" || code == "japanese" { tokenizer.setLanguage(.japanese) }
            if code == "ko" || code == "korean" { tokenizer.setLanguage(.korean) }
            if code == "th" || code == "thai" { tokenizer.setLanguage(.thai) }
            var words: [String] = []
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in words.append(String(text[range])); return true }
            return words
        }
        var result: [String] = []
        for part in text.split(whereSeparator: \.isWhitespace) {
            var buffer = ""
            for scalar in part.unicodeScalars {
                let han = (0x3400...0x9FFF).contains(Int(scalar.value)) || (0xF900...0xFAFF).contains(Int(scalar.value))
                if han {
                    if !buffer.isEmpty {
                        result.append(buffer)
                        buffer = ""
                    }
                    result.append(String(scalar))
                } else {
                    let char = Character(scalar)
                    if char.isPunctuation || ",.!?;:，。！？；：、".contains(char) {
                        if !buffer.isEmpty {
                            buffer.append(char)
                        } else if var last = result.last {
                            last.append(char)
                            result[result.count - 1] = last
                        } else {
                            buffer.append(char)
                        }
                    } else {
                        buffer.append(char)
                    }
                }
            }
            if !buffer.isEmpty { result.append(buffer) }
        }
        return result
    }
}

nonisolated enum Qwen3TimestampCorrection {
    static func monotonic(_ values: [Int]) -> [Int] {
        guard values.count > 1 else { return values }
        let anchors = longestIncreasingSubsequencePositions(values)
        guard !anchors.isEmpty else { return values }
        let anchorSet = Set(anchors)
        var result = values
        for index in values.indices where !anchorSet.contains(index) {
            let previous = anchors.last(where: { $0 < index })
            let next = anchors.first(where: { $0 > index })
            switch (previous, next) {
            case let (.some(left), .some(right)):
                if right - left <= 3 {
                    result[index] = index - left <= right - index ? values[left] : values[right]
                } else {
                    let fraction = Float(index - left) / Float(right - left)
                    result[index] = values[left] + Int(fraction * Float(values[right] - values[left]))
                }
            case let (.some(left), .none): result[index] = values[left]
            case let (.none, .some(right)): result[index] = values[right]
            case (.none, .none): break
            }
        }
        for index in 1..<result.count where result[index] < result[index - 1] { result[index] = result[index - 1] }
        return result
    }

    private static func longestIncreasingSubsequencePositions(_ values: [Int]) -> [Int] {
        var tails: [Int] = [], tailIndices: [Int] = []
        var parent = [Int](repeating: -1, count: values.count)
        for index in values.indices {
            var low = 0, high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if tails[middle] < values[index] { low = middle + 1 } else { high = middle }
            }
            if low == tails.count { tails.append(values[index]); tailIndices.append(index) }
            else { tails[low] = values[index]; tailIndices[low] = index }
            if low > 0 { parent[index] = tailIndices[low - 1] }
        }
        guard var cursor = tailIndices.last else { return [] }
        var positions: [Int] = []
        while cursor >= 0 { positions.append(cursor); cursor = parent[cursor] }
        return positions.reversed()
    }
}
#endif
