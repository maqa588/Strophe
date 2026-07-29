//
//  AutoCaptionView+Process+Execution.swift
//  Strophe
//
//  Created by Antigravity on 2026/07/12.
//

import SwiftUI

extension AutoCaptionView {

    func startCaptioningProcess() {
        guard let mediaURL = project.videoURL else { return }

        runningMode = .local
        isRunning = true
        currentStep = 0
        stepProgress = 0.0
        statusMessage = localizedAIText("status_checking_device_compatibility")

        Task {
            do {
                try AIBackendClient.ensureLocalAIAvailable()

                // 0. 模型依赖预下载阶段
                let isWhisperDownloaded = modelManager.downloadedWhisperModels.contains(selectedModel)
                if !isWhisperDownloaded {
                    statusMessage = localizedAIFormat(
                        "status_downloading_asr_model_format",
                        selectedModel
                    )

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
                            userInfo: [
                                NSLocalizedDescriptionKey: localizedAIText(
                                    "error_asr_model_download_failed"
                                )
                            ]
                        )
                    }
                }

                let useCoreMLASRAcceleration = enableCoreMLASRAcceleration && LocalModelManager.supportsCoreMLASRAcceleration(selectedModel)
                let coreMLASRModelName = LocalModelManager.coreMLASRAccelerationModelName
                if useCoreMLASRAcceleration && !modelManager.downloadedWhisperModels.contains(coreMLASRModelName) {
                    statusMessage = localizedAIFormat(
                        "status_downloading_coreml_asr_format",
                        coreMLASRModelName
                    )
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
                            userInfo: [
                                NSLocalizedDescriptionKey: localizedAIText(
                                    "error_coreml_asr_download_failed"
                                )
                            ]
                        )
                    }
                }

                let usesNativeTimestamps = LocalModelManager.usesNativeTimestamps(
                    selectedModel
                )
                let needsAligner = (enableAlignment || enableDiarization || generateKaraoke)
                    && !usesNativeTimestamps
                let isAlignerDownloaded = modelManager.downloadedAlignerModels.contains(selectedAlignerModel)
                if needsAligner && !isAlignerDownloaded {
                    statusMessage = localizedAIFormat(
                        "status_downloading_aligner_format",
                        selectedAlignerModel
                    )
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
                            userInfo: [
                                NSLocalizedDescriptionKey: localizedAIText(
                                    "error_aligner_download_failed"
                                )
                            ]
                        )
                    }
                }

                if useVAD {
                    let vadModelName = LocalModelManager.vadPresets.first?.name ?? "firered-vad-coreml"
                    let isVADDownloaded = modelManager.downloadedVADModels.contains(vadModelName)
                    if !isVADDownloaded {
                        let displayName = (vadModelName == "firered-vad-coreml") ? "FireRed VAD" : "VAD"
                        let approxSize = LocalModelManager.vadPresets
                            .first(where: { $0.name == vadModelName })?
                            .localizedSize ?? ""
                        statusMessage = localizedAIFormat(
                            "status_downloading_named_model_format",
                            displayName,
                            approxSize
                        )
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
                                userInfo: [
                                    NSLocalizedDescriptionKey: localizedAIFormat(
                                        "error_named_model_download_failed_format",
                                        displayName
                                    )
                                ]
                            )
                        }
                    }
                }

                let isSpeakerDownloaded = modelManager.downloadedSpeakerModels.contains("pyannote-diarization-mlx")
                if enableDiarization && !isSpeakerDownloaded {
                    statusMessage = localizedAIFormat(
                        "status_downloading_speaker_model_format",
                        "pyannote-diarization-mlx"
                    )
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
                            userInfo: [
                                NSLocalizedDescriptionKey: localizedAIText(
                                    "error_speaker_model_download_failed"
                                )
                            ]
                        )
                    }
                }

                // 0.2 智能降噪模型预下载阶段
                if vocalPreprocessing == "denoise" {
                    let isDenoiseDownloaded = modelManager.downloadedOtherModels.contains("deepfilternet3-coreml")
                    if !isDenoiseDownloaded {
                        statusMessage = localizedAIText(
                            "status_downloading_denoise_model"
                        )
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
                                userInfo: [
                                    NSLocalizedDescriptionKey: localizedAIText(
                                        "error_denoise_model_download_failed"
                                    )
                                ]
                            )
                        }
                    }
                }

                // 0.3 伴奏人声分离模型预下载阶段
                if vocalPreprocessing == "separate" {
                    let isSpleeterDownloaded = modelManager.downloadedOtherModels.contains("spleeter2-coreml")
                    if !isSpleeterDownloaded {
                        statusMessage = localizedAIText(
                            "status_downloading_vocal_separation_model"
                        )
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
                                userInfo: [
                                    NSLocalizedDescriptionKey: localizedAIText(
                                        "error_vocal_separation_model_download_failed"
                                    )
                                ]
                            )
                        }
                    }
                }

                // 1. 提取并采样音频数据
                let whisperBaseDir = modelManager.getBaseDirectory(for: .whisper)
                // 使用外置模型根目录下的 Hub-style 路径 (base/org/repo)。
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
                        userInfo: [
                            NSLocalizedDescriptionKey: localizedAIFormat(
                                "error_unknown_aligner_format",
                                selectedAlignerModel
                            )
                        ]
                    )
                }

                let vadBaseDir = modelManager.getBaseDirectory(for: .vad)
                let vadPresetName = LocalModelManager.vadPresets.first?.name ?? "firered-vad-coreml"
                let vadModelURL: URL
                if let hubDir = modelManager.getModelDirectory(for: vadPresetName, type: .vad) {
                    vadModelURL = hubDir
                } else {
                    let folderName = LocalModelManager.vadPresets.first?.folderName ?? "firered-vad-coreml"
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
                    asrModelName: selectedModel,
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
                    enableAlignment: (enableAlignment || generateKaraoke) && !usesNativeTimestamps,
                    vocalPreprocessing: vocalPreprocessing,
                    referenceText: referenceLyrics,
                    useVAD: useVAD
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

                let generatedSubtitles = subtitleItems(
                    from: results,
                    karaokeEnabled: generateKaraoke
                )
                guard !generatedSubtitles.isEmpty else {
                    throw NSError(
                        domain: "AutoCaptionView",
                        code: 11,
                        userInfo: [
                            NSLocalizedDescriptionKey: localizedAIText(
                                "error_local_recognition_empty"
                            )
                        ]
                    )
                }

                // 3. 部署到 Timeline 并注册撤销
                await MainActor.run {
                    replaceProjectSubtitles(with: generatedSubtitles, actionName: String(localized: "local_ai_speech_recognition_alignment"))
                    finishSuccessfulGeneration(
                        message: localizedAIFormat(
                            "status_local_generation_complete_format",
                            generatedSubtitles.count
                        )
                    )
                }

                try? await Task.sleep(nanoseconds: 1_200_000_000)

                await MainActor.run {
                    dismiss()
                }

            } catch {
                await MainActor.run {
                    finishFailedGeneration(error)
                }
            }
        }
    }

    func startCloudCaptioningProcess() {
        guard let mediaURL = project.videoURL else { return }

        runningMode = .cloud
        isRunning = true
        currentStep = 0
        stepProgress = 0.0
        statusMessage = localizedAIText("status_preparing_cloud_recognition")

        Task {
            do {
                statusMessage = localizedAIText("status_checking_cloud_service")
                let baseURL = try AIBackendClient.normalizedCloudBaseURL(from: cloudBaseURLString)
                cloudBaseURLString = baseURL.absoluteString
                let connectionCheck = try await AIBackendClient.shared.testCloudConnection(
                    baseURL: baseURL,
                    model: selectedCloudModel
                )
                guard connectionCheck.isReady else {
                    cloudConnectionTestState = .failed(connectionCheck.message)
                    throw NSError(
                        domain: "AIBackendClient.CloudConnection",
                        code: 31,
                        userInfo: [NSLocalizedDescriptionKey: connectionCheck.message]
                    )
                }
                cloudConnectionTestState = .succeeded(connectionCheck.message)

                let cloudLanguage = selectedCloudModel == .parakeetJA
                    ? "ja"
                    : selectedLanguage
                let request = AICloudGenerateSubtitlesRequest(
                    mediaURL: mediaURL,
                    endpointURL: AIBackendClient.cloudTranscribeURL(baseURL: baseURL),
                    language: cloudLanguage,
                    model: selectedCloudModel,
                    enableKaraoke: generateKaraoke
                )

                let result = try await AIBackendClient.shared.generateCloudSubtitles(
                    request: request,
                    progressCallback: { step, subProgress, message in
                        Task { @MainActor in
                            self.currentStep = step
                            self.statusMessage = message

                            let overallProgress: Double
                            switch step {
                            case 0: overallProgress = 0.0 + subProgress * 0.20
                            case 1: overallProgress = 0.20 + subProgress * 0.20
                            case 2: overallProgress = 0.40 + subProgress * 0.55
                            case 3: overallProgress = 0.95 + subProgress * 0.05
                            default: overallProgress = subProgress
                            }
                            self.stepProgress = min(1.0, max(0.0, overallProgress))
                        }
                    }
                )

                let generatedSubtitles = subtitleItems(
                    from: result.segments,
                    karaokeEnabled: generateKaraoke
                )
                guard !generatedSubtitles.isEmpty else {
                    throw NSError(
                        domain: "AutoCaptionView",
                        code: 12,
                        userInfo: [
                            NSLocalizedDescriptionKey: localizedAIText(
                                "error_cloud_recognition_empty"
                            )
                        ]
                    )
                }

                await MainActor.run {
                    if let language = result.language, !language.isEmpty {
                        finishSuccessfulGeneration(
                            message: localizedAIFormat(
                                "status_cloud_generation_complete_language_format",
                                generatedSubtitles.count,
                                localizedRecognitionLanguageName(language)
                            )
                        )
                    } else {
                        finishSuccessfulGeneration(
                            message: localizedAIFormat(
                                "status_cloud_generation_complete_format",
                                generatedSubtitles.count
                            )
                        )
                    }
                    replaceProjectSubtitles(with: generatedSubtitles, actionName: String(localized: "cloud_ai_speech_recognition_alignment"))
                }

                try? await Task.sleep(nanoseconds: 1_200_000_000)

                await MainActor.run {
                    dismiss()
                }
            } catch {
                let displayError = AIBackendClient.userFacingCloudError(error)
                await MainActor.run {
                    cloudConnectionTestState = .failed(displayError.localizedDescription)
                    finishFailedGeneration(displayError)
                }
            }
        }
    }
}
