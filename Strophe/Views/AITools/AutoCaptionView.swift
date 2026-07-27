//
//  AutoCaptionView.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/28.
//

import SwiftUI

enum CaptionGenerationMode: Sendable {
    case local
    case cloud
}

enum CloudConnectionTestState: Equatable {
    case idle
    case testing
    case succeeded(String)
    case failed(String)
}

struct AutoCaptionView: View {
    @ObservedObject var project: SubtitleProject
    @StateObject var modelManager = LocalModelManager.shared
    @Environment(\.dismiss) var dismiss
    
    // Config states
    @State var selectedModel: String = LocalModelManager.coreMLASRAccelerationModelName
    @State var enableCoreMLASRAcceleration: Bool = true
    @State var selectedAlignerModel: String = LocalModelManager.forcedAlignerINT8ModelName
    @State var enableAlignment: Bool = true
    @State var selectedLanguage: String = "auto"
    @State var enableDiarization: Bool = false
    @State var speakerCountOption: String = "auto" // "auto" or "custom"
    @State var customSpeakerCount: Int = 2
    @State var prefixSpeakerName: Bool = false
    @State var vocalPreprocessing: String = "none"
    @State var referenceLyrics: String = ""
    @State var useVAD: Bool = true
    @State var selectedCloudModel: AICloudASRModel = .qwen3ASR17B
    @AppStorage(AIBackendClient.cloudBaseURLDefaultsKey)
    var cloudBaseURLString: String = AIBackendClient.defaultCloudBaseURL.absoluteString
    @State var cloudConnectionTestState: CloudConnectionTestState = .idle
    
    // UI steps & running state
    @State var selectedGenerationMode: CaptionGenerationMode? = nil
    @State var isRunning: Bool = false
    @State var runningMode: CaptionGenerationMode = .local
    @State var currentStep: Int = 0
    @State var stepProgress: Double = 0.0
    @State var statusMessage: String = ""
    @State var showUnsupportedLocalAIAlert: Bool = false
    @State var showGenerationErrorAlert: Bool = false
    @State var generationErrorMessage: String = ""

    init(project: SubtitleProject) {
        self.project = project
        let recommendedModel = LocalModelManager.recommendedASRModelName()
        let recommendedCloudModel = AICloudASRModel.recommended()
        _selectedModel = State(initialValue: recommendedModel)
        _selectedCloudModel = State(initialValue: recommendedCloudModel)
        _selectedLanguage = State(
            initialValue: LocalModelManager.isParakeetJA(recommendedModel)
                || recommendedCloudModel == .parakeetJA
                ? "ja"
                : "auto"
        )
    }
    
    let languages = [
        ("auto",  "auto_detect"),
        ("zh",    "recognition_language_simplified_chinese"),
        ("zh-TW", "recognition_language_traditional_chinese"),
        ("en",    "recognition_language_english"),
        ("ja",    "recognition_language_japanese"),
        ("ko",    "recognition_language_korean"),
        ("fr",    "recognition_language_french"),
        ("de",    "recognition_language_german"),
        ("es",    "recognition_language_spanish"),
        ("ru",    "recognition_language_russian")
    ]
    
    var body: some View {
        #if os(macOS)
        mainContent
            .frame(width: 480, height: 600)
            .background(VisualEffectView(material: .sheet, blendingMode: .behindWindow))
            .alert(AIBackendClient.unsupportedDeviceMessage, isPresented: $showUnsupportedLocalAIAlert) {
                Button("ok", role: .cancel) {}
            } message: {
                Text(AIBackendClient.cloudComingSoonMessage)
            }
            .alert("generation_failed", isPresented: $showGenerationErrorAlert) {
                Button("ok", role: .cancel) {}
            } message: {
                Text(generationErrorMessage)
            }
            .stropheOnChange(of: selectedModel) { modelName in
                if LocalModelManager.isParakeetJA(modelName) {
                    selectedLanguage = "ja"
                }
            }
            .stropheOnChange(of: selectedCloudModel) { model in
                if model == .parakeetJA {
                    selectedLanguage = "ja"
                }
            }
            .stropheOnChange(of: selectedLanguage) { language in
                updateRecommendedCloudModel(for: language)
            }
        #else
        simpleIOSBody
            .alert(AIBackendClient.unsupportedDeviceMessage, isPresented: $showUnsupportedLocalAIAlert) {
                Button("ok", role: .cancel) {}
            } message: {
                Text(AIBackendClient.cloudComingSoonMessage)
            }
            .alert("generation_failed", isPresented: $showGenerationErrorAlert) {
                Button("ok", role: .cancel) {}
            } message: {
                Text(generationErrorMessage)
            }
            .stropheOnChange(of: selectedModel) { modelName in
                if LocalModelManager.isParakeetJA(modelName) {
                    selectedLanguage = "ja"
                }
            }
            .stropheOnChange(of: selectedCloudModel) { model in
                if model == .parakeetJA {
                    selectedLanguage = "ja"
                }
            }
            .stropheOnChange(of: selectedLanguage) { language in
                updateRecommendedCloudModel(for: language)
            }
        #endif
    }

    var isLocalAIIncludedInBuild: Bool {
        AIBackendClient.isLocalAIIncludedInBuild
    }

    var isLocalAISupported: Bool {
        AIBackendClient.isLocalDeviceSupported
    }

    var canStartLocalCaptioning: Bool {
        isLocalAIIncludedInBuild && isLocalAISupported && areRequiredLocalModelsDownloaded && project.videoURL != nil && !isRunning
    }

    var areRequiredLocalModelsDownloaded: Bool {
        let needsAligner = (enableAlignment || enableDiarization)
            && !LocalModelManager.usesNativeTimestamps(selectedModel)
        return modelManager.downloadedWhisperModels.contains(selectedModel)
            && (!needsAligner
                || modelManager.downloadedAlignerModels.contains(selectedAlignerModel))
            && (!useVAD || modelManager.downloadedVADModels.contains("firered-vad-coreml"))
    }

    var isParakeetJASelected: Bool {
        LocalModelManager.isParakeetJA(selectedModel)
    }

    var isCloudParakeetJASelected: Bool {
        selectedCloudModel == .parakeetJA
    }

    var isCurrentRecognitionJapaneseOnly: Bool {
        selectedGenerationMode == .cloud
            ? isCloudParakeetJASelected
            : isParakeetJASelected
    }

    var availableASRModels: [AIModelInfo] {
        let recommended = LocalModelManager.recommendedASRModelName()
        return LocalModelManager.whisperPresets.sorted {
            ($0.name == recommended ? 0 : 1) < ($1.name == recommended ? 0 : 1)
        }
    }

    func modelPickerTitle(_ model: AIModelInfo) -> String {
        let downloadState = localizedModelDownloadState(
            downloaded: modelManager.downloadedWhisperModels.contains(model.name)
        )
        let recommendation = model.name == LocalModelManager.recommendedASRModelName()
            ? " · " + NSLocalizedString("recommended_model", comment: "Recommended model")
            : ""
        return "\(model.name) (\(model.localizedSize))\(recommendation) [\(downloadState)]"
    }

    func auxiliaryModelPickerTitle(
        _ model: AIModelInfo,
        downloaded: Bool
    ) -> String {
        "\(model.name) (\(model.localizedSize)) [\(localizedModelDownloadState(downloaded: downloaded))]"
    }

    private func localizedModelDownloadState(downloaded: Bool) -> String {
        downloaded
            ? NSLocalizedString("model_downloaded", comment: "Model download state")
            : NSLocalizedString("model_not_downloaded", comment: "Model download state")
    }

    var localMissingModelsHintKey: String {
        if isParakeetJASelected {
            return useVAD
                ? "local_generation_missing_parakeet_vad_hint"
                : "local_generation_missing_parakeet_hint"
        }
        return useVAD
            ? "local_generation_missing_models_vad_hint"
            : "local_generation_missing_models_aligner_hint"
    }

    var localVADExplanationKey: String {
        isParakeetJASelected
            ? "auto_caption_vad_parakeet_explanation"
            : "auto_caption_vad_explanation"
    }

    var canStartCloudCaptioning: Bool {
        project.videoURL != nil && configuredCloudBaseURL != nil && !isRunning
    }

    var configuredCloudBaseURL: URL? {
        try? AIBackendClient.normalizedCloudBaseURL(from: cloudBaseURLString)
    }

    var configuredCloudTranscribeURL: URL? {
        configuredCloudBaseURL.map(AIBackendClient.cloudTranscribeURL(baseURL:))
    }

    var localRecognitionStatusText: String {
        guard isLocalAIIncludedInBuild else { return "unavailable" }
        return isLocalAISupported ? "available" : "unavailable"
    }

    var localRecognitionDetailText: String {
        guard isLocalAIIncludedInBuild else {
            return AIBackendClient.unsupportedDeviceMessage
        }
        return isLocalAISupported
            ? localizedAIText("local_recognition_detail")
            : AIBackendClient.unsupportedDeviceMessage
    }

    func localizedAIText(_ key: String) -> String {
        NSLocalizedString(key, comment: "AI subtitle generation")
    }

    func localizedAIFormat(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: NSLocalizedString(key, comment: "AI subtitle generation"),
            arguments: arguments
        )
    }

    func localizedRecognitionLanguageName(_ identifier: String) -> String {
        let normalized = identifier.lowercased()
        let aliases: [String: String] = [
            "chinese": "zh",
            "english": "en",
            "japanese": "ja",
            "korean": "ko",
            "french": "fr",
            "german": "de",
            "spanish": "es",
            "russian": "ru",
        ]
        let code = aliases[normalized]
            ?? languages.first(where: {
                normalized == $0.0.lowercased()
                    || normalized.hasPrefix($0.0.lowercased() + "-")
            })?.0
        guard let code,
              let key = languages.first(where: { $0.0 == code })?.1 else {
            return identifier
        }
        return localizedAIText(key)
    }

    var cloudRecognitionDetailText: String {
        let address = configuredCloudTranscribeURL?.absoluteString ?? cloudBaseURLString
        return "\(selectedCloudModel.displayName) · \(address)"
    }

    var orderedCloudModels: [AICloudASRModel] {
        let recommended = AICloudASRModel.recommended()
        return AICloudASRModel.allCases.sorted {
            ($0 == recommended ? 0 : 1) < ($1 == recommended ? 0 : 1)
        }
    }

    func cloudModelPickerTitle(_ model: AICloudASRModel) -> String {
        let recommendation = model == AICloudASRModel.recommended()
            ? " · " + NSLocalizedString("recommended_model", comment: "Recommended model")
            : ""
        return model.displayName + recommendation
    }

    func updateRecommendedCloudModel(for language: String) {
        guard selectedGenerationMode == .cloud else { return }
        if language == "ja" {
            selectedCloudModel = .parakeetJA
        } else if language != "auto", selectedCloudModel == .parakeetJA {
            selectedCloudModel = .qwen3ASR17B
        }
    }

    func handleChooseLocalButton() {
        guard isLocalAIIncludedInBuild, isLocalAISupported else {
            showUnsupportedLocalAIAlert = true
            return
        }
        selectedGenerationMode = .local
    }

    func handleChooseCloudButton() {
        selectedGenerationMode = .cloud
        updateRecommendedCloudModel(for: selectedLanguage)
    }

    func handleStartLocalButton() {
        guard isLocalAIIncludedInBuild, isLocalAISupported else {
            showUnsupportedLocalAIAlert = true
            return
        }
        guard areRequiredLocalModelsDownloaded else { return }
        startCaptioningProcess()
    }

    func handleStartCloudButton() {
        startCloudCaptioningProcess()
    }

    func triggerCloudLocalNetworkPermission() {
        guard let baseURL = configuredCloudBaseURL else { return }
        AIBackendClient.triggerLocalNetworkPrivacyAlert(for: baseURL)
    }

    func handleTestCloudConnection() {
        guard cloudConnectionTestState != .testing else { return }
        cloudConnectionTestState = .testing

        Task {
            do {
                let baseURL = try AIBackendClient.normalizedCloudBaseURL(from: cloudBaseURLString)
                cloudBaseURLString = baseURL.absoluteString
                let check = try await AIBackendClient.shared.testCloudConnection(
                    baseURL: baseURL,
                    model: selectedCloudModel
                )
                cloudConnectionTestState = check.isReady
                    ? .succeeded(check.message)
                    : .failed(check.message)
            } catch {
                let displayError = AIBackendClient.userFacingCloudError(error)
                cloudConnectionTestState = .failed(displayError.localizedDescription)
            }
        }
    }
    
    func cleanSubtitleText(_ text: String) -> String {
        var result = text
        
        // 剔除 Qwen ASR3 经常生成的卡顿字
        let hesitationWords = ["嗯", "啊", "呃"]
        for word in hesitationWords {
            result = result.replacingOccurrences(of: word, with: "")
        }
        
        // Remove periods, semicolons, and question marks (both Chinese and English)
        let toRemove = ["。", ".", "；", ";", "？", "?"]
        for char in toRemove {
            result = result.replacingOccurrences(of: char, with: "")
        }
        
        // Replace commas with spaces (both Chinese and English)
        let toReplaceWithSpace = ["，", ","]
        for char in toReplaceWithSpace {
            result = result.replacingOccurrences(of: char, with: " ")
        }

        // 剔除 Qwen3-ASR 偶发泄漏的 prompt 指令 "language None"
        result = result.replacingOccurrences(of: "language None", with: "", options: .caseInsensitive)

        // Collapse multiple spaces into one
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        
        // Trim leading and trailing spaces
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Toggle Checkbox Style Helpers
extension ToggleStyle where Self == CheckboxToggleStyle {
    static var checkboxIfSupported: CheckboxToggleStyle { CheckboxToggleStyle() }
}

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack(spacing: 8) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Color.stropheAccent : .secondary)
                    .font(.title3)
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}
