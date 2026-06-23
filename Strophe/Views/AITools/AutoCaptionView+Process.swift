//
//  AutoCaptionView+Process.swift
//  Strophe
//
//  Created by Antigravity on 2026/06/04.
//

import SwiftUI

extension AutoCaptionView {
    
    @ViewBuilder
    var runningStateView: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Modern floating processing circle
            ZStack {
                Circle()
                    .stroke(Color.stropheBorder, lineWidth: 8)
                    .frame(width: 140, height: 140)
                
                Circle()
                    .trim(from: 0, to: CGFloat(stepProgress))
                    .stroke(
                        AngularGradient(colors: [Color.stropheAccent, Color.stropheAccent.opacity(0.3)], center: .center),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 140, height: 140)
                    .animation(.easeInOut, value: stepProgress)
                
                VStack(spacing: 4) {
                    Text(stepProgress, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.stropheText)
                    
                    Text("进度")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Steps layout - 对应高精度 Golden Pipeline 的工作流步骤
            VStack(alignment: .leading, spacing: 14) {
                let preprocessingTitle: String = {
                    switch vocalPreprocessing {
                    case "none": return "第一步: 提取音频..."
                    case "separate": return "第一步: 伴奏人声分离 (Spleeter)..."
                    default: return "第一步: 智能降噪 (DeepFilterNet3)..."
                    }
                }()
                let stepTitles = enableDiarization ? [
                    preprocessingTitle,
                    "第二步: 语音识别转写 (Qwen3-ASR)...",
                    "第三步: 毫秒级字词对齐 (ForcedAligner)...",
                    "第四步: 发言角色声纹分离 (Pyannote)..."
                ] : [
                    preprocessingTitle,
                    "第二步: 语音识别转写 (Qwen3-ASR)...",
                    "第三步: 毫秒级字词对齐 (ForcedAligner)...",
                    "第四步: 字幕片段整合输出..."
                ]
                
                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: 12) {
                        ZStack {
                            if currentStep > index {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if currentStep == index {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Circle()
                                    .fill(Color.stropheBorder)
                                    .frame(width: 16, height: 16)
                            }
                        }
                        .frame(width: 20, height: 20)
                        
                        Text(stepTitles[index])
                            .font(.subheadline)
                            .foregroundStyle(currentStep == index ? Color.stropheText : .secondary)
                            .fontWeight(currentStep == index ? .semibold : .regular)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 36)
            
            // Status Info
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            
            Spacer()
        }
        .padding(.vertical, 24)
    }
    
    func startCaptioningProcess() {
        guard let mediaURL = project.videoURL else { return }
        
        isRunning = true
        currentStep = 0
        stepProgress = 0.0
        statusMessage = "正在检查设备兼容性..."
        
        Task {
            do {
                try AIBackendClient.ensureLocalAIAvailable()

                // 1. 内存检查 (>= 3.7GB)
                let physicalMemory = ProcessInfo.processInfo.physicalMemory
                if physicalMemory < 3_700_000_000 {
                    let memoryInGB = Double(physicalMemory) / (1024.0 * 1024.0 * 1024.0)
                    throw NSError(
                        domain: "AutoCaptionView",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: String(format: "当前设备运行内存不足 (%.1f GB)，本地 AI 运行至少需要约 3.7GB 内存以防闪退。", memoryInGB)]
                    )
                }

                // 0. 模型依赖预下载阶段
                let isWhisperDownloaded = modelManager.downloadedWhisperModels.contains(selectedModel)
                if !isWhisperDownloaded {
                    statusMessage = "正在从 Hugging Face 下载 ASR 模型 \(selectedModel) (约需几分钟)..."
                    
                    let downloadTask = Task {
                        let whisperModelId = "Whisper_\(selectedModel)"
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            await MainActor.run {
                                if let progress = modelManager.downloadProgresses[whisperModelId] {
                                    self.stepProgress = progress * 0.95
                                }
                            }
                        }
                    }
                    
                    await modelManager.downloadModel(type: .whisper, modelName: selectedModel)
                    downloadTask.cancel()
                    
                    let whisperCheck = modelManager.downloadedWhisperModels.contains(selectedModel)
                    if !whisperCheck {
                        throw NSError(
                            domain: "AutoCaptionView",
                            code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "语音转写模型下载失败，请检查网络连接。"]
                        )
                    }
                }

                let useCoreMLASRAcceleration = enableCoreMLASRAcceleration && LocalModelManager.supportsCoreMLASRAcceleration(selectedModel)
                let coreMLASRModelName = LocalModelManager.coreMLASRAccelerationModelName
                if useCoreMLASRAcceleration && !modelManager.downloadedWhisperModels.contains(coreMLASRModelName) {
                    statusMessage = "正在从 Hugging Face 下载 CoreML ASR 编码器 \(coreMLASRModelName)..."
                    self.stepProgress = 0.0

                    let downloadTask = Task {
                        let coreMLModelId = "Whisper_\(coreMLASRModelName)"
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            await MainActor.run {
                                if let progress = modelManager.downloadProgresses[coreMLModelId] {
                                    self.stepProgress = progress * 0.95
                                }
                            }
                        }
                    }

                    await modelManager.downloadModel(type: .whisper, modelName: coreMLASRModelName)
                    downloadTask.cancel()

                    let coreMLCheck = modelManager.downloadedWhisperModels.contains(coreMLASRModelName)
                    if !coreMLCheck {
                        throw NSError(
                            domain: "AutoCaptionView",
                            code: 10,
                            userInfo: [NSLocalizedDescriptionKey: "CoreML ASR 编码器下载失败，请检查网络连接。"]
                        )
                    }
                }

                let needsAligner = enableAlignment || enableDiarization
                let isAlignerDownloaded = modelManager.downloadedAlignerModels.contains(selectedAlignerModel)
                if needsAligner && !isAlignerDownloaded {
                    statusMessage = "正在从 Hugging Face 下载强制对齐模型 \(selectedAlignerModel)..."
                    self.stepProgress = 0.0

                    let downloadTask = Task {
                        let alignerModelId = "ForcedAligner_\(selectedAlignerModel)"
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            await MainActor.run {
                                if let progress = modelManager.downloadProgresses[alignerModelId] {
                                    self.stepProgress = progress * 0.95
                                }
                            }
                        }
                    }

                    await modelManager.downloadModel(type: .aligner, modelName: selectedAlignerModel)
                    downloadTask.cancel()

                    let alignerCheck = modelManager.downloadedAlignerModels.contains(selectedAlignerModel)
                    if !alignerCheck {
                        throw NSError(
                            domain: "AutoCaptionView",
                            code: 8,
                            userInfo: [NSLocalizedDescriptionKey: "强制对齐模型下载失败，请检查网络连接。"]
                        )
                    }
                }
                
                let vadModelName = "pyannote-segmentation-3.0-mlx"
                let isVADDownloaded = modelManager.downloadedVADModels.contains(vadModelName)
                if !isVADDownloaded {
                    statusMessage = "正在从 Hugging Face 下载 Pyannote VAD 模型 \(vadModelName) (约 5.7MB)..."
                    self.stepProgress = 0.0

                    let downloadTask = Task {
                        let vadModelId = "VADKit_\(vadModelName)"
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            await MainActor.run {
                                if let progress = modelManager.downloadProgresses[vadModelId] {
                                    self.stepProgress = progress * 0.95
                                }
                            }
                        }
                    }

                    await modelManager.downloadModel(type: .vad, modelName: vadModelName)
                    downloadTask.cancel()

                    let vadCheck = modelManager.downloadedVADModels.contains(vadModelName)
                    if !vadCheck {
                        throw NSError(
                            domain: "AutoCaptionView",
                            code: 10,
                            userInfo: [NSLocalizedDescriptionKey: "Pyannote VAD 模型下载失败，请检查网络连接。"]
                        )
                    }
                }

                let isSpeakerDownloaded = modelManager.downloadedSpeakerModels.contains("pyannote-diarization-mlx")
                if enableDiarization && !isSpeakerDownloaded {
                    statusMessage = "正在从 Hugging Face 下载声纹识别模型 pyannote-diarization-mlx (约需几分钟)..."
                    self.stepProgress = 0.0
                    
                    let downloadTask = Task {
                        let speakerModelId = "SpeakerKit_pyannote-diarization-mlx"
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            await MainActor.run {
                                if let progress = modelManager.downloadProgresses[speakerModelId] {
                                    self.stepProgress = progress * 0.95
                                }
                            }
                        }
                    }
                    
                    await modelManager.downloadModel(type: .speaker, modelName: "pyannote-diarization-mlx")
                    downloadTask.cancel()
                    
                    let speakerCheck = modelManager.downloadedSpeakerModels.contains("pyannote-diarization-mlx")
                    if !speakerCheck {
                        throw NSError(
                            domain: "AutoCaptionView",
                            code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "声纹识别模型下载失败，请检查网络连接。"]
                        )
                    }
                }
                
                // 0.2 智能降噪模型预下载阶段
                if vocalPreprocessing == "denoise" {
                    let isDenoiseDownloaded = modelManager.downloadedOtherModels.contains("deepfilternet3-coreml")
                    if !isDenoiseDownloaded {
                        statusMessage = "正在从 Hugging Face 下载智能降噪模型..."
                        self.stepProgress = 0.0
                        
                        let downloadTask = Task {
                            let denoiseModelId = "Other_deepfilternet3-coreml"
                            while !Task.isCancelled {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                await MainActor.run {
                                    if let progress = modelManager.downloadProgresses[denoiseModelId] {
                                        self.stepProgress = progress * 0.95
                                    }
                                }
                            }
                        }
                        
                        await modelManager.downloadModel(type: .other, modelName: "deepfilternet3-coreml")
                        downloadTask.cancel()
                        
                        let denoiseCheck = modelManager.downloadedOtherModels.contains("deepfilternet3-coreml")
                        if !denoiseCheck {
                            throw NSError(
                                domain: "AutoCaptionView",
                                code: 6,
                                userInfo: [NSLocalizedDescriptionKey: "智能降噪模型下载失败，请检查网络连接。"]
                            )
                        }
                    }
                }
                
                // 0.3 伴奏人声分离模型预下载阶段
                if vocalPreprocessing == "separate" {
                    let isSpleeterDownloaded = modelManager.downloadedOtherModels.contains("spleeter2-coreml")
                    if !isSpleeterDownloaded {
                        statusMessage = "正在下载伴奏人声分离模型..."
                        self.stepProgress = 0.0
                        
                        let downloadTask = Task {
                            let spleeterModelId = "Other_spleeter2-coreml"
                            while !Task.isCancelled {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                await MainActor.run {
                                    if let progress = modelManager.downloadProgresses[spleeterModelId] {
                                        self.stepProgress = progress * 0.95
                                    }
                                }
                            }
                        }
                        
                        await modelManager.downloadModel(type: .other, modelName: "spleeter2-coreml")
                        downloadTask.cancel()
                        
                        let spleeterCheck = modelManager.downloadedOtherModels.contains("spleeter2-coreml")
                        if !spleeterCheck {
                            throw NSError(
                                domain: "AutoCaptionView",
                                code: 7,
                                userInfo: [NSLocalizedDescriptionKey: "伴奏人声分离模型下载失败，请检查网络连接。"]
                            )
                        }
                    }
                }
                
                // 1. 提取并采样音频数据
                let whisperBaseDir = modelManager.getBaseDirectory(for: .whisper)
                // 使用 Hub-style 路径 (base/models/org/repo)；fallback 到旧版扁平路径
                let selectedASRModelURL: URL
                if let hubDir = modelManager.getModelDirectory(for: selectedModel, type: .whisper) {
                    selectedASRModelURL = hubDir
                } else {
                    let folderName = LocalModelManager.whisperPresets.first(where: { $0.name == selectedModel })?.folderName ?? selectedModel
                    selectedASRModelURL = whisperBaseDir.appendingPathComponent(folderName)
                }
                let whisperModelURL: URL
                let asrDecoderModelURL: URL?
                if useCoreMLASRAcceleration {
                    if let hubDir = modelManager.getModelDirectory(for: coreMLASRModelName, type: .whisper) {
                        whisperModelURL = hubDir
                    } else {
                        let folderName = LocalModelManager.coreMLASRAccelerationPreset.folderName
                        whisperModelURL = whisperBaseDir.appendingPathComponent(folderName)
                    }
                    asrDecoderModelURL = selectedASRModelURL
                } else {
                    whisperModelURL = selectedASRModelURL
                    asrDecoderModelURL = nil
                }

                let alignerBaseDir = modelManager.getBaseDirectory(for: .aligner)
                let alignerModelURL: URL
                if let hubDir = modelManager.getModelDirectory(for: selectedAlignerModel, type: .aligner) {
                    alignerModelURL = hubDir
                } else {
                    let folderName = LocalModelManager.alignerPresets.first(where: { $0.name == selectedAlignerModel })?.folderName ?? selectedAlignerModel
                    alignerModelURL = alignerBaseDir.appendingPathComponent(folderName)
                }

                guard let alignerModelId = modelManager.huggingFaceModelId(for: selectedAlignerModel) else {
                    throw NSError(
                        domain: "AutoCaptionView",
                        code: 9,
                        userInfo: [NSLocalizedDescriptionKey: "未知的强制对齐模型：\(selectedAlignerModel)"]
                    )
                }

                let vadBaseDir = modelManager.getBaseDirectory(for: .vad)
                let vadPresetName = LocalModelManager.vadPresets.first?.name ?? "pyannote-segmentation-3.0-mlx"
                let vadModelURL: URL
                if let hubDir = modelManager.getModelDirectory(for: vadPresetName, type: .vad) {
                    vadModelURL = hubDir
                } else {
                    let folderName = LocalModelManager.vadPresets.first?.folderName ?? "pyannote-segmentation-3.0-mlx"
                    vadModelURL = vadBaseDir.appendingPathComponent(folderName)
                }

                let speakerBaseDir = modelManager.getBaseDirectory(for: .speaker)
                let speakerModelName = LocalModelManager.speakerPresets.first?.name ?? "pyannote-diarization-mlx"
                let speakerModelURL: URL
                if let hubDir = modelManager.getModelDirectory(for: speakerModelName, type: .speaker) {
                    speakerModelURL = hubDir
                } else {
                    let folderName = LocalModelManager.speakerPresets.first?.folderName ?? "pyannote-diarization-mlx"
                    speakerModelURL = speakerBaseDir.appendingPathComponent(folderName)
                }
                
                let expectedSpeakersCount: Int? = (speakerCountOption == "custom") ? customSpeakerCount : nil
                
                let request = AIGenerateSubtitlesRequest(
                    audioURL: mediaURL,
                    whisperModelURL: whisperModelURL,
                    asrDecoderModelURL: asrDecoderModelURL,
                    alignerModelURL: alignerModelURL,
                    vadModelURL: vadModelURL,
                    speakerModelURL: speakerModelURL,
                    whisperBaseDir: whisperBaseDir,
                    alignerBaseDir: alignerBaseDir,
                    speakerBaseDir: speakerBaseDir,
                    alignerModelId: alignerModelId,
                    modelStorageRoot: modelManager.resolvedExternalURL(),
                    expectedSpeakers: expectedSpeakersCount,
                    language: selectedLanguage,
                    enableDiarization: enableDiarization,
                    prefixSpeakerName: prefixSpeakerName,
                    enableAlignment: enableAlignment,
                    vocalPreprocessing: vocalPreprocessing,
                    referenceText: referenceLyrics
                )

                let results = try await AIBackendClient.shared.generateSubtitles(
                    request: request,
                    progressCallback: { step, subProgress, message in
                        Task { @MainActor in
                            self.currentStep = step
                            self.statusMessage = message
                            
                            // 映射每一步的分段进度至总进度环
                            let overallProgress: Double
                            if self.enableDiarization {
                                switch step {
                                case 0: overallProgress = 0.0 + subProgress * 0.15
                                case 1: overallProgress = 0.15 + subProgress * 0.40
                                case 2: overallProgress = 0.55 + subProgress * 0.20
                                case 3: overallProgress = 0.75 + subProgress * 0.25
                                default: overallProgress = subProgress
                                }
                            } else {
                                switch step {
                                case 0: overallProgress = 0.0 + subProgress * 0.15
                                case 1: overallProgress = 0.15 + subProgress * 0.50
                                case 2: overallProgress = 0.65 + subProgress * 0.20
                                case 3: overallProgress = 0.85 + subProgress * 0.15
                                default: overallProgress = subProgress
                                }
                            }
                            self.stepProgress = overallProgress
                        }
                    }
                )
                
                let generatedSubtitles = results.enumerated().compactMap { index, seg -> SubtitleItem? in
                    let cleaned = cleanSubtitleText(seg.text)
                    
                    // 去除可能存在的说话人标签后再检查是否为空
                    var textWithoutSpeaker = cleaned
                    if textWithoutSpeaker.hasPrefix("["), let endBracket = textWithoutSpeaker.firstIndex(of: "]") {
                        let startIndex = textWithoutSpeaker.index(after: endBracket)
                        textWithoutSpeaker = String(textWithoutSpeaker[startIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    
                    // 如果字幕块最终只有“嗯啊呃”或标点符号（即剥离说话人标签后为空），则丢弃该字幕块
                    if textWithoutSpeaker.isEmpty {
                        return nil
                    }
                    
                    return SubtitleItem(
                        text: cleaned,
                        startTime: seg.startTime,
                        endTime: seg.endTime,
                        originalIndex: index
                    )
                }
                
                // 3. 部署到 Timeline 并注册撤销
                await MainActor.run {
                    let oldItems = project.items
                    let oldSelectedIDs = project.selectedIDs
                    project.items = generatedSubtitles
                    project.undoManager.registerUndo(withTarget: project) { target in
                        target.items = oldItems
                        target.selectedIDs = oldSelectedIDs
                        target.notifyChange()
                    }
                    project.undoManager.setActionName(String(localized: "AI 语音识别打轴"))
                    project.currentIndex = 0
                    project.notifyChange()
                    
                    stepProgress = 1.0
                    statusMessage = "完成！成功生成 \(generatedSubtitles.count) 条字幕。"
                }
                
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                
                await MainActor.run {
                    dismiss()
                }
                
            } catch {
                await MainActor.run {
                    isRunning = false
                    statusMessage = "生成失败: \(error.localizedDescription)"
                }
            }
        }
    }
}
