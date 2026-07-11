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

struct AutoCaptionView: View {
    @ObservedObject var project: SubtitleProject
    @StateObject var modelManager = LocalModelManager.shared
    @Environment(\.dismiss) var dismiss
    
    // Config states
    @State var selectedModel: String = LocalModelManager.coreMLASRAccelerationModelName
    @State var enableCoreMLASRAcceleration: Bool = true
    @State var selectedAlignerModel: String = "qwen3-forced-aligner-0.6b-coreml-int8"
    @State var enableAlignment: Bool = true
    @State var selectedLanguage: String = "auto"
    @State var enableDiarization: Bool = false
    @State var speakerCountOption: String = "auto" // "auto" or "custom"
    @State var customSpeakerCount: Int = 2
    @State var prefixSpeakerName: Bool = false
    @State var vocalPreprocessing: String = "none"
    @State var referenceLyrics: String = ""
    @State var useVAD: Bool = true
    
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
    
    let languages = [
        ("auto",  "auto_detect"),
        ("zh",    "简体中文 (Simplified Chinese)"),
        ("zh-TW", "繁體中文 (Traditional Chinese)"),
        ("en",    "英文 (English)"),
        ("ja",    "日文 (Japanese)"),
        ("ko",    "韩文 (Korean)"),
        ("fr",    "法文 (French)"),
        ("de",    "德文 (German)"),
        ("es",    "西班牙文 (Spanish)"),
        ("ru",    "俄文 (Russian)")
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
        modelManager.downloadedWhisperModels.contains(LocalModelManager.coreMLASRAccelerationModelName)
            && modelManager.downloadedAlignerModels.contains(selectedAlignerModel)
            && (!useVAD || modelManager.downloadedVADModels.contains("firered-vad-coreml"))
    }

    var canStartCloudCaptioning: Bool {
        project.videoURL != nil && !isRunning
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
            ? "使用端侧 Qwen3-ASR、ForcedAligner 与本地模型配置。"
            : AIBackendClient.unsupportedDeviceMessage
    }

    var cloudRecognitionDetailText: String {
        "提交到 \(AIBackendClient.defaultCloudTranscribeURL.absoluteString)，返回完整句子时间轴。"
    }

    func handleChooseLocalButton() {
        guard isLocalAIIncludedInBuild, isLocalAISupported else {
            showUnsupportedLocalAIAlert = true
            return
        }
        selectedGenerationMode = .local
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
