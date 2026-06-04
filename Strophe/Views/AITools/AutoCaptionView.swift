//
//  AutoCaptionView.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/28.
//

import SwiftUI

struct AutoCaptionView: View {
    @ObservedObject var project: SubtitleProject
    @StateObject var modelManager = LocalModelManager.shared
    @Environment(\.dismiss) var dismiss
    
    // Config states
    @State var selectedModel: String = "qwen3-asr-0.6b"
    @State var selectedAlignerModel: String = "qwen3-forced-aligner-0.6b-mlx-4bit"
    @State var enableAlignment: Bool = true
    @State var selectedLanguage: String = "auto"
    @State var enableDiarization: Bool = false
    @State var speakerCountOption: String = "auto" // "auto" or "custom"
    @State var customSpeakerCount: Int = 2
    @State var prefixSpeakerName: Bool = false
    @State var vocalPreprocessing: String = "denoise"
    @State var referenceLyrics: String = ""
    
    // UI steps & running state
    @State var isRunning: Bool = false
    @State var currentStep: Int = 0
    @State var stepProgress: Double = 0.0
    @State var statusMessage: String = ""
    @State var showUnsupportedLocalAIAlert: Bool = false
    
    let languages = [
        ("auto",  "自动检测"),
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
                Button("好", role: .cancel) {}
            } message: {
                Text(AIBackendClient.cloudComingSoonMessage)
            }
        #else
        iosBody
            .alert(AIBackendClient.unsupportedDeviceMessage, isPresented: $showUnsupportedLocalAIAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(AIBackendClient.cloudComingSoonMessage)
            }
        #endif
    }

    var isLocalAISupported: Bool {
        AIBackendClient.isLocalDeviceSupported
    }

    var canStartCaptioning: Bool {
        isLocalAISupported && project.videoURL != nil && !isRunning
    }

    func handleStartButton() {
        guard isLocalAISupported else {
            showUnsupportedLocalAIAlert = true
            return
        }
        startCaptioningProcess()
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
