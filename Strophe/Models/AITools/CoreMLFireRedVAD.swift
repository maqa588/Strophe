#if STROPHE_LOCAL_AI
import Accelerate
import CoreML
import Foundation

/// FireRedVAD (Stream-VAD, Xiaohongshu/小红书) CoreML 封装。
///
/// 替换原 Silero VAD，使用 DFSMN 流式因果模型 (lookahead=0)：
/// - 80 维 Kaldi 风格 log-Mel filterbank 特征（Povey 窗、预加重 0.97、去直流、功率谱、Kaldi mel 尺度、ln 压缩）
/// - GLOBAL CMVN 固定统计量（80 均值 + 80 逆标准差，从 cmvn.ark 提取并硬编码）
/// - 8 层 FSMN lookback cache [1,128,19]，零初始化，逐批更新
/// - 5 帧因果滑动平均平滑，阈值 0.5
///
/// 参考：https://huggingface.co/illitan/FireRedVAD-CoreML
@available(iOS 18.0, macOS 15.0, *)
nonisolated final class CoreMLFireRedVAD {
    let model: MLModel
    private let fbank: FireRedFbankExtractor

    init(directory: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try CoreMLModelLoader.load(named: "FireRedVAD", from: directory, configuration: configuration)
        fbank = FireRedFbankExtractor()
    }

    struct VoiceIsland {
        let startSample: Int
        let endSample: Int
        var startTime: Double { Double(startSample) / 16000.0 }
        var endTime: Double { Double(endSample) / 16000.0 }
    }

    // MARK: - Streaming inference

    /// 对一段 16kHz 单声道 PCM 进行流式 VAD，返回语音岛列表。
    ///
    /// 保持与 Silero 实现一致的对外签名（基于样本数的阈值/静音/最短/最长参数），
    /// 内部按帧（frameShift=160 样本）进行概率估计后转换为样本边界。
    func findVoiceIslands(
        samples: [Float],
        threshold: Float = 0.5,
        minSilenceSamples: Int = 12800, // 0.8 s @ 16kHz
        minSpeechSamples: Int = 4000,   // 0.25 s @ 16kHz
        maxSpeechSamples: Int = 320000  // 20 s @ 16kHz
    ) throws -> [VoiceIsland] {
        guard !samples.isEmpty else { return [] }
        let frameShift = 160
        let frameLength = 400

        // snip_edges=true: 仅在完整 400 样本窗内取帧
        let totalSamples = samples.count
        guard totalSamples >= frameLength else { return [] }
        let frameCount = (totalSamples - frameLength) / frameShift + 1

        // 1. 提取 80 维 FBank 特征（含 CMVN）
        let features = fbank.extract(samples: samples, frameCount: frameCount)

        // 2. 流式批量推理（T=512），获取每帧语音概率
        let probs = try inferStreamed(features: features, frameCount: frameCount)

        #if DEBUG
        if let minimum = probs.min(), let maximum = probs.max() {
            let mean = probs.reduce(0, +) / Float(probs.count)
            print("FireRedVAD 概率: min=\(minimum), mean=\(mean), max=\(maximum), threshold=\(threshold)")
        }
        #endif

        // 3. 5 帧因果滑动平均平滑
        let smoothed = smooth(probs: probs)

        // 4. 将基于样本的参数换算为帧数
        let minSilenceFrames = max(1, Int((Float(minSilenceSamples) / Float(frameShift)).rounded()))
        let minSpeechFrames = max(1, Int((Float(minSpeechSamples) / Float(frameShift)).rounded()))
        let maxSpeechFrames = max(1, Int((Float(maxSpeechSamples) / Float(frameShift)).rounded()))

        // 5. 基于帧级别的状态机检测语音岛
        var rawIslands: [VoiceIsland] = []
        var isSpeaking = false
        var speechStartFrame = 0
        var silenceCount = 0

        for frameIdx in 0..<frameCount {
            let isSpeech = smoothed[frameIdx] >= threshold
            if isSpeech {
                if !isSpeaking {
                    isSpeaking = true
                    speechStartFrame = frameIdx
                }
                silenceCount = 0
                // 连续语音同样必须执行最大长度限制。原逻辑只在静音分支
                // 检查，整段音乐/歌声会一直延伸到文件末尾。
                if frameIdx - speechStartFrame + 1 >= maxSpeechFrames {
                    let startSample = speechStartFrame * frameShift
                    let endSample = min(totalSamples, (frameIdx + 1) * frameShift)
                    rawIslands.append(VoiceIsland(startSample: startSample, endSample: endSample))
                    isSpeaking = false
                }
            } else {
                if isSpeaking {
                    silenceCount += 1
                    let speechFrames = frameIdx - silenceCount - speechStartFrame + 1
                    if silenceCount >= minSilenceFrames || speechFrames >= maxSpeechFrames {
                        let speechEndFrame = frameIdx - silenceCount
                        if (speechEndFrame - speechStartFrame + 1) >= minSpeechFrames {
                            let startSample = speechStartFrame * frameShift
                            let endSample = min(totalSamples, (speechEndFrame + 1) * frameShift)
                            rawIslands.append(VoiceIsland(startSample: startSample, endSample: endSample))
                        }
                        isSpeaking = false
                    }
                }
            }
        }

        if isSpeaking {
            let speechEndFrame = frameCount - 1
            if (speechEndFrame - speechStartFrame + 1) >= minSpeechFrames {
                let startSample = speechStartFrame * frameShift
                let endSample = min(totalSamples, (speechEndFrame + 1) * frameShift)
                rawIslands.append(VoiceIsland(startSample: startSample, endSample: endSample))
            }
        }

        // 6. 250ms 双侧 padding + 重叠合并
        let padSamples = 4000
        var paddedIslands: [VoiceIsland] = []
        for raw in rawIslands {
            let start = max(0, raw.startSample - padSamples)
            let end = min(totalSamples, raw.endSample + padSamples)
            paddedIslands.append(VoiceIsland(startSample: start, endSample: end))
        }

        var merged: [VoiceIsland] = []
        for island in paddedIslands {
            if let last = merged.last {
                if island.startSample <= last.endSample {
                    let mergedEnd = max(last.endSample, island.endSample)
                    merged[merged.count - 1] = VoiceIsland(startSample: last.startSample, endSample: mergedEnd)
                } else {
                    merged.append(island)
                }
            } else {
                merged.append(island)
            }
        }
        // Padding 会令相邻的最大长度岛重叠并再次合并，因此返回前重新
        // 强制切分，维持调用方依赖的 maxSpeechSamples 不变量。
        return splitIslands(merged, maxSamples: maxSpeechSamples)
    }

    private func splitIslands(_ islands: [VoiceIsland], maxSamples: Int) -> [VoiceIsland] {
        guard maxSamples > 0 else { return islands }
        var result: [VoiceIsland] = []
        for island in islands {
            var start = island.startSample
            while start < island.endSample {
                let end = min(island.endSample, start + maxSamples)
                result.append(VoiceIsland(startSample: start, endSample: end))
                start = end
            }
        }
        return result
    }

    // MARK: - Inference

    private func inferStreamed(features: [Float], frameCount: Int) throws -> [Float] {
        let melBins = 80
        let batchSize = 512
        var probs = [Float](repeating: 0, count: frameCount)

        // 8 个 FSMN lookback cache，零初始化 [1,128,19]
        var caches: [MLMultiArray] = []
        for _ in 0..<8 {
            let cache = try MLMultiArray(shape: [1, 128, 19], dataType: .float32)
            let ptr = cache.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<(1 * 128 * 19) { ptr[i] = 0 }
            caches.append(cache)
        }

        var offset = 0
        while offset < frameCount {
            let t = min(batchSize, frameCount - offset)
            let feat = try MLMultiArray(shape: [1, NSNumber(value: t), 80], dataType: .float32)
            let featPtr = feat.dataPointer.assumingMemoryBound(to: Float.self)
            for row in 0..<t {
                let srcBase = (offset + row) * melBins
                let dstBase = row * melBins
                for col in 0..<melBins { featPtr[dstBase + col] = features[srcBase + col] }
            }

            var dictionary: [String: MLFeatureValue] = ["feat": MLFeatureValue(multiArray: feat)]
            for i in 0..<8 {
                dictionary["cache_\(i)"] = MLFeatureValue(multiArray: caches[i])
            }

            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: dictionary))
            guard let probsArray = output.featureValue(for: "probs")?.multiArrayValue else {
                throw NSError(domain: "CoreMLFireRedVAD", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少 probs 输出"])
            }
            let probsPtr = probsArray.dataPointer.assumingMemoryBound(to: Float.self)
            // probs 形状 [1, T, 1]
            let probsStride = (probsArray.strides.count >= 2) ? probsArray.strides[1].intValue : t
            for row in 0..<t {
                probs[offset + row] = probsPtr[row * probsStride]
            }

            // 更新缓存
            for i in 0..<8 {
                if let next = output.featureValue(for: "new_cache_\(i)")?.multiArrayValue {
                    caches[i] = next
                }
            }
            offset += t
        }
        return probs
    }

    /// 5 帧因果滑动平均（仅使用当前及过去 4 帧）。
    private func smooth(probs: [Float]) -> [Float] {
        let window = 5
        guard probs.count > 0 else { return probs }
        var out = [Float](repeating: 0, count: probs.count)
        var sum: Float = 0
        var ringBuffer = [Float](repeating: 0, count: window)
        var ringIdx = 0
        var filled = 0
        for i in 0..<probs.count {
            sum -= ringBuffer[ringIdx]
            ringBuffer[ringIdx] = probs[i]
            sum += probs[i]
            ringIdx = (ringIdx + 1) % window
            if filled < window { filled += 1 }
            out[i] = sum / Float(filled)
        }
        return out
    }
}

// MARK: - Kaldi-style FBank Feature Extractor

/// 80 维 Kaldi 风格 log-Mel filterbank 特征提取器（匹配 FireRedVAD/kaldi_native_fbank）。
///
/// 配置：
/// - 16kHz，帧长 25ms (400 samples)，帧移 10ms (160 samples)
/// - FFT 512，80 mel bins，20–8000 Hz（Kaldi mel 尺度 1127*ln(1+f/700)）
/// - Povey 窗 pow(0.5-0.5*cos(2πn/(N-1)), 0.85)
/// - 预加重 0.97（反向），去直流
/// - snip_edges=true，ln(max(energy, float epsilon))
@available(iOS 18.0, macOS 15.0, *)
nonisolated private final class FireRedFbankExtractor {
    private let frameLength = 400
    private let frameShift = 160
    private let fftSize = 512
    private let melBins = 80
    private let lowFreq: Float = 20.0
    private let highFreq: Float = 8000.0
    private let sampleRate: Float = 16000.0
    private let preemph: Float = 0.97

    private let window: [Float]
    private let melFilters: [(startBin: Int, weights: [Float])]
    private let fftSetup: FFTSetup

    init() {
        window = Self.poveyWindow(length: 400)
        fftSetup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!
        melFilters = Self.computeMelFilterbank(
            nBins: 257, nMel: 80, sampleRate: 16000,
            lowFreq: 20.0, highFreq: 8000.0
        )
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// 提取 FBank 特征并应用 GLOBAL CMVN。
    /// - Parameters:
      ///   - samples: 完整音频 PCM
    ///   - frameCount: 帧数（snip_edges=true 时由调用方计算）
    /// - Returns: [frameCount * 80] 的展平特征数组（行优先，每帧连续 80 维）
    func extract(samples: [Float], frameCount: Int) -> [Float] {
        var output = [Float](repeating: 0, count: frameCount * melBins)
        var work = [Float](repeating: 0, count: frameLength)
        var frame = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var power = [Float](repeating: 0, count: 257)

        for frameIdx in 0..<frameCount {
            let start = frameIdx * frameShift
            // 1. 复制 400 样本帧并恢复为 Kaldi/FireRedVAD 训练时使用的
            // Int16 PCM 数值尺度。AudioExtractor 的 AV_SAMPLE_FMT_FLT 输出是
            // [-1, 1]；上游 FireRedVAD 则通过 soundfile(dtype="int16") 将
            // 约 [-32768, 32767] 的样本送进 kaldi_native_fbank。漏掉该缩放
            // 会让 log-Mel 整体低约 ln(32768^2)，CMVN 后模型几乎只输出静音。
            for i in 0..<frameLength {
                work[i] = max(-1, min(1, samples[start + i])) * 32768
            }
            // 2. 去直流
            var mean: Float = 0
            vDSP_sve(work, 1, &mean, vDSP_Length(frameLength))
            mean /= Float(frameLength)
            var negMean = -mean
            vDSP_vsadd(work, 1, &negMean, &work, 1, vDSP_Length(frameLength))
            // 3. 预强调（反向，Kaldi 风格）
            for i in stride(from: frameLength - 1, through: 1, by: -1) {
                work[i] -= preemph * work[i - 1]
            }
            work[0] -= preemph * work[0] // = work[0] * (1 - preemph)
            // 4. Povey 窗
            vDSP_vmul(work, 1, window, 1, &work, 1, vDSP_Length(frameLength))
            // 5. 零填充至 512 并 FFT
            for i in 0..<frameLength { frame[i] = work[i] }
            for i in frameLength..<fftSize { frame[i] = 0 }
            for i in 0..<(fftSize / 2) {
                real[i] = frame[i * 2]
                imag[i] = frame[i * 2 + 1]
            }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imag.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &split, 1, 9, FFTDirection(kFFTDirection_Forward))
                }
            }
            // 6. 功率谱 |X[k]|^2（vDSP_fft_zrip 输出含 1/2 缩放，需平方后乘 4 还原；Kaldi 参考使用原始 |X|^2，这里保持一致）
            power[0] = real[0] * real[0] * 4
            power[fftSize / 2] = imag[0] * imag[0] * 4
            for bin in 1..<(fftSize / 2) {
                power[bin] = (real[bin] * real[bin] + imag[bin] * imag[bin]) * 4
            }
            // 7. 应用 Mel filterbank + ln 压缩
            let epsilon: Float = 1.1920929e-7 // f32::EPSILON
            let base = frameIdx * melBins
            for m in 0..<melBins {
                let filter = melFilters[m]
                var energy: Float = 0
                let weights = filter.weights
                let weightsCount = weights.count
                weights.withUnsafeBufferPointer { wBuf in
                    power.withUnsafeBufferPointer { pBuf in
                        vDSP_dotpr(pBuf.baseAddress! + filter.startBin, 1,
                                   wBuf.baseAddress!, 1, &energy,
                                   vDSP_Length(weightsCount))
                    }
                }
                let safe = max(energy, epsilon)
                output[base + m] = log(safe)
            }
        }

        // 8. GLOBAL CMVN: (x - mean) * inv_std
        let mean = Self.cmvnMean
        let invStd = Self.cmvnInvStd
        for frameIdx in 0..<frameCount {
            let base = frameIdx * melBins
            for m in 0..<melBins {
                output[base + m] = (output[base + m] - mean[m]) * invStd[m]
            }
        }
        return output
    }

    // MARK: - Window & Filterbank

    private static func poveyWindow(length: Int) -> [Float] {
        var w = [Float](repeating: 0, count: length)
        let n = Float(length - 1)
        for i in 0..<length {
            let hann = 0.5 - 0.5 * cosf(2 * Float.pi * Float(i) / n)
            w[i] = powf(hann, 0.85)
        }
        return w
    }

    /// Kaldi mel 尺度: 1127 * ln(1 + f/700)
    @inline(__always)
    private static func melScale(_ freq: Float) -> Float {
        1127.0 * logf(1.0 + freq / 700.0)
    }

    private static func computeMelFilterbank(
        nBins: Int, nMel: Int, sampleRate: Float,
        lowFreq: Float, highFreq: Float
    ) -> [(startBin: Int, weights: [Float])] {
        let melLow = melScale(lowFreq)
        let melHigh = melScale(highFreq)
        let melDelta = (melHigh - melLow) / Float(nMel + 1)
        let fftBinWidth = sampleRate / Float(512) // FFT_SIZE
        var filters: [(startBin: Int, weights: [Float])] = []
        filters.reserveCapacity(nMel)

        for m in 0..<nMel {
            let leftMel = melLow + Float(m) * melDelta
            let centerMel = melLow + Float(m + 1) * melDelta
            let rightMel = melLow + Float(m + 2) * melDelta
            var startBin = nBins
            var weights: [Float] = []
            for i in 0..<nBins {
                let freq = fftBinWidth * Float(i)
                let mel = melScale(freq)
                if mel > leftMel && mel < rightMel {
                    let weight: Float
                    if mel <= centerMel {
                        weight = (mel - leftMel) / (centerMel - leftMel)
                    } else {
                        weight = (rightMel - mel) / (rightMel - centerMel)
                    }
                    if startBin == nBins { startBin = i }
                    let expectedIdx = i - startBin
                    while weights.count < expectedIdx { weights.append(0) }
                    weights.append(weight)
                }
            }
            if startBin == nBins { startBin = 0 }
            filters.append((startBin, weights))
        }
        return filters
    }

    // MARK: - CMVN (GLOBAL fixed stats, extracted from cmvn.ark)

    private static let cmvnMean: [Float] = [
        10.42295174919564, 10.862097411631494, 11.764544378124809, 12.490164701573908,
        13.25983008289003, 13.89594383242307, 14.364940238918987, 14.593948347480778,
        14.749723601612253, 14.668315348346496, 14.730796723156509, 14.775052459167833,
        14.9890519821556, 15.178004932637085, 15.253520314586988, 15.328637048782031,
        15.334018588850057, 15.288641702136166, 15.4276616890477, 15.246266155846598,
        15.092573799088989, 15.290421940704482, 15.07575008669762, 15.186772872540853,
        15.088673242416798, 15.170797396442111, 15.070178088017926, 15.150795340269006,
        15.108532832116397, 15.115345080167454, 15.141279987705998, 15.131832359605129,
        15.145195868641611, 15.19151892676777, 15.235478667211774, 15.306369752614641,
        15.373021476906201, 15.416394625766584, 15.459857436373436, 15.39143273165164,
        15.46357624247469, 15.399661212735632, 15.462907917820873, 15.441629120393843,
        15.484969525295984, 15.552401775001249, 15.638091925650645, 15.705489346158819,
        15.767008852632651, 15.855123781367105, 15.867269782501769, 15.891537408746947,
        15.9231448295521, 15.978382613315533, 16.014801667676718, 16.048674939996204,
        16.082029914992358, 16.09680075379873, 16.093736693349236, 16.07247919506059,
        16.075509664672943, 16.02227087563821, 15.976762101902347, 15.89786454765505,
        15.812741644368487, 15.711205109067762, 15.604198886052728, 15.553519438005933,
        15.51025275187747, 15.460023817226517, 15.4156843628003, 15.37602764551613,
        15.328348980305998, 15.295370796331634, 15.185470194591382, 15.017044975516262,
        14.905080029850632, 14.623806569017782, 14.138093813776406, 13.313870348004635
    ]

    private static let cmvnInvStd: [Float] = [
        0.2494980879825924, 0.23563235243542163, 0.23145152525802104, 0.2332233926481505,
        0.23182660283718737, 0.22853356937894798, 0.2243486976577694, 0.21898920450844725,
        0.21832438092730974, 0.22082592767700662, 0.2229673556813116, 0.22288416257259386,
        0.22234810686081127, 0.22100642502031184, 0.21994202276343874, 0.22005444019015313,
        0.22070092118977014, 0.22150809748461409, 0.22236667273698002, 0.22305291750035372,
        0.22335341587062665, 0.22438905727453648, 0.22547701626910854, 0.2269007560258811,
        0.22823023223045188, 0.22931472070164832, 0.23046728075908798, 0.23083553439603108,
        0.23143382733873202, 0.2322065940520882, 0.2325798897870885, 0.2336197007969686,
        0.23437240620327746, 0.23508252486137127, 0.23578078965798868, 0.235892002292441,
        0.2360209777141303, 0.23663799549538955, 0.2374987640063862, 0.2379845180109627,
        0.23899377757763487, 0.239748152899516, 0.24030835895648858, 0.2409769361661754,
        0.24143248909906587, 0.24135465696291541, 0.24079937967447773, 0.24047405396120294,
        0.23995525139180407, 0.23952287673801784, 0.2394808893818449, 0.2393650908183211,
        0.23929339134427347, 0.23902199338028696, 0.23857873289710127, 0.23814701563685442,
        0.23804621120577427, 0.23824193788738984, 0.2386009552212688, 0.23915406501238878,
        0.23922540730102645, 0.2393830803524144, 0.2397336021407156, 0.2396056154523928,
        0.24028502694537057, 0.2406181323375118, 0.2406792985927079, 0.24096201908324874,
        0.24043605546026958, 0.24021526735270676, 0.23972514279402155, 0.23871998076352863,
        0.2374413126648784, 0.23619509194955604, 0.23337281484306663, 0.2268023271445609,
        0.2257750261856693, 0.22503847248255957, 0.2263113742246566, 0.2289949344716713
    ]
}
#endif
