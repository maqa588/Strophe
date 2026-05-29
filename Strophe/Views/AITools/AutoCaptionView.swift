//
//  AutoCaptionView.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/28.
//

import SwiftUI

struct AutoCaptionView: View {
    @ObservedObject var project: SubtitleProject
    @StateObject private var modelManager = LocalModelManager.shared
    @Environment(\.dismiss) private var dismiss
    
    // Config states - 默认修改为推荐的 qwen3-asr-0.6b 模型
    @State private var selectedModel: String = "qwen3-asr-0.6b"
    @State private var selectedAlignerModel: String = "qwen3-forced-aligner-0.6b-mlx-4bit"
    @State private var selectedLanguage: String = "auto"
    @State private var enableDiarization: Bool = false
    @State private var speakerCountOption: String = "auto" // "auto" or "custom"
    @State private var customSpeakerCount: Int = 2
    @State private var prefixSpeakerName: Bool = false
    @State private var vocalPreprocessing: String = "denoise"
    @State private var referenceLyrics: String = ""
    
    // UI steps & running state
    @State private var isRunning: Bool = false
    @State private var currentStep: Int = 0
    @State private var stepProgress: Double = 0.0
    @State private var statusMessage: String = ""
    
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
        #else
        iosBody
        #endif
    }

    #if !os(macOS)
    @ViewBuilder
    private var iosBody: some View {
        NavigationView {
            Form {
                if isRunning {
                    Section {
                        runningStateView
                    }
                } else {
                    // Media source warning or info
                    Section {
                        if project.videoURL == nil {
                            HStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.title2)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("未加载媒体")
                                        .fontWeight(.semibold)
                                    Text("请先导入视频或音频文件再使用语音识别功能。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            HStack {
                                Image(systemName: "play.rectangle.fill")
                                    .foregroundStyle(Color.stropheAccent)
                                Text("当前媒体: \(project.documentDisplayName)")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .foregroundStyle(Color.stropheText)
                            }
                        }
                    }
                    
                    Section {
                        // Model Selection
                        Picker("模型选择", selection: $selectedModel) {
                            ForEach(LocalModelManager.whisperPresets, id: \.name) { model in
                                let isDownloaded = modelManager.downloadedWhisperModels.contains(model.name)
                                Text("\(model.name) (\(model.size)) \(isDownloaded ? "[已下载]" : "[未下载]")")
                                    .tag(model.name)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        
                        let isSelectedDownloaded = modelManager.downloadedWhisperModels.contains(selectedModel)
                        if !isSelectedDownloaded {
                            Text("提示：此模型尚未下载，开始生成时会从 Hugging Face 自动下载该模型。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        // Language Selection
                        Picker("识别语言", selection: $selectedLanguage) {
                            ForEach(languages, id: \.0) { item in
                                Text(item.1).tag(item.0)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        
                        // Preprocessing Selection
                        VStack(alignment: .leading, spacing: 6) {
                            Text("人声预处理")
                                .font(.subheadline)
                            Picker("预处理", selection: $vocalPreprocessing) {
                                Text("不处理").tag("none")
                                Text("智能降噪").tag("denoise")
                                Text("人声分离").tag("separate")
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("语音识别配置 (Qwen3-ASR)")
                    }
                    
                    Section {
                        // Aligner Model
                        Picker("对齐器模型", selection: $selectedAlignerModel) {
                            ForEach(LocalModelManager.alignerPresets, id: \.name) { model in
                                let isDownloaded = modelManager.downloadedAlignerModels.contains(model.name)
                                Text("\(model.name) (\(model.size)) \(isDownloaded ? "[已下载]" : "[未下载]")")
                                    .tag(model.name)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        
                        if selectedAlignerModel.contains("coreml") {
                            Text("当前依赖暂未提供 CoreML ForcedAligner 推理接口；可下载备用，实际生成请先选 MLX 4-bit。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Text("强制对齐配置 (Qwen3-ForcedAligner)")
                    }
                    
                    Section {
                        Toggle("启用对话人识别 (Pyannote)", isOn: $enableDiarization)
                            .tint(Color.stropheAccent)
                        
                        if enableDiarization {
                            Picker("发言人数", selection: $speakerCountOption) {
                                Text("自动检测").tag("auto")
                                Text("指定人数").tag("custom")
                            }
                            .pickerStyle(.segmented)
                            
                            if speakerCountOption == "custom" {
                                Stepper("发言人数量: \(customSpeakerCount) 人", value: $customSpeakerCount, in: 1...10)
                            }
                            
                            Toggle("在字幕中添加发言人前缀", isOn: $prefixSpeakerName)
                                .tint(Color.stropheAccent)
                        }
                    } header: {
                        Text("对话人识别")
                    }
                    
                    Section {
                        TextEditor(text: $referenceLyrics)
                            .frame(minHeight: 100)
                            .font(.system(.body, design: .rounded))
                    } header: {
                        Text("参考歌词（可选）")
                    } footer: {
                        Text("歌曲建议粘贴逐行歌词；系统会跳过自由识别，直接按这些歌词强制对齐。")
                    }
                }
            }
            .navigationTitle("AI 自动生成字幕")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                    .disabled(isRunning)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isRunning {
                        ProgressView()
                    } else {
                        Button("开始") {
                            startCaptioningProcess()
                        }
                        .fontWeight(.bold)
                        .disabled(project.videoURL == nil)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
    #endif
    
    private var mainContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("AI 自动生成字幕")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.stropheText)
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(isRunning)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)
            
            Divider()
                .background(Color.stropheBorder)
            
            if isRunning {
                runningStateView
            } else {
                configurationForm
            }
            
            Divider()
                .background(Color.stropheBorder)
            
            // Bottom Actions
            HStack {
                Spacer()
                
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(isRunning)
                .tint(Color.stropheText)
                
                Button(action: startCaptioningProcess) {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 8)
                    } else {
                        Text("开始生成")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stropheAccent)
                .disabled(isRunning || project.videoURL == nil)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }
    
    // MARK: - Configuration View
    private var configurationForm: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Media Source Check
                if project.videoURL == nil {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.title2)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("未加载媒体")
                                .fontWeight(.semibold)
                            Text("请先导入视频或音频文件再使用语音识别功能。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.stropheSecondaryBackground)
                    .cornerRadius(12)
                } else {
                    HStack {
                        Image(systemName: "play.rectangle.fill")
                            .foregroundStyle(Color.stropheAccent)
                        Text("当前媒体: \(project.documentDisplayName)")
                            .font(.subheadline)
                            .lineLimit(1)
                            .foregroundStyle(Color.stropheText)
                        Spacer()
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.stropheSecondaryBackground)
                    .cornerRadius(12)
                }
                
                // Section 1: Qwen3-ASR Config
                VStack(alignment: .leading, spacing: 12) {
                    Text("语音识别配置 (Qwen3-ASR)")
                        .font(.headline)
                        .foregroundStyle(Color.stropheText)
                    
                    // Model Selection
                    VStack(alignment: .leading, spacing: 6) {
                        Text("模型选择")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Picker("模型", selection: $selectedModel) {
                            ForEach(LocalModelManager.whisperPresets, id: \.name) { model in
                                let isDownloaded = modelManager.downloadedWhisperModels.contains(model.name)
                                Text("\(model.name) (\(model.size)) \(isDownloaded ? "[已下载]" : "[未下载]")")
                                    .tag(model.name)
                            }
                        }
                        .pickerStyle(.menu)
                        
                        let isSelectedDownloaded = modelManager.downloadedWhisperModels.contains(selectedModel)
                        if !isSelectedDownloaded {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(Color.stropheAccent)
                                Text("提示：此模型尚未下载，开始生成时会从 Hugging Face 自动下载该模型。")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        }
                    }
                    
                    // Language Selection
                    VStack(alignment: .leading, spacing: 6) {
                        Text("识别语言")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Picker("识别语言", selection: $selectedLanguage) {
                            ForEach(languages, id: \.0) { item in
                                Text(item.1).tag(item.0)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Preprocessing Selection
                    VStack(alignment: .leading, spacing: 6) {
                        Text("人声预处理")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Picker("预处理", selection: $vocalPreprocessing) {
                            Text("安静人声 (不处理)").tag("none")
                            Text("嘈杂人声 (智能降噪)").tag("denoise")
                            Text("背景音乐 (人声分离)").tag("separate")
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("参考歌词（可选）")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $referenceLyrics)
                            .font(.system(.body, design: .rounded))
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color.stropheBackground.opacity(0.7))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.stropheBorder, lineWidth: 1)
                            )

                        Text("歌曲建议粘贴逐行歌词；系统会跳过自由识别，直接按这些歌词强制对齐。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.stropheSecondaryBackground.opacity(0.5))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.stropheBorder, lineWidth: 1)
                )
                
                // Section 2: Pyannote Diarization Config
                VStack(alignment: .leading, spacing: 12) {
                    Text("强制对齐配置 (Qwen3-ForcedAligner)")
                        .font(.headline)
                        .foregroundStyle(Color.stropheText)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("对齐器模型")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("对齐器模型", selection: $selectedAlignerModel) {
                            ForEach(LocalModelManager.alignerPresets, id: \.name) { model in
                                let isDownloaded = modelManager.downloadedAlignerModels.contains(model.name)
                                Text("\(model.name) (\(model.size)) \(isDownloaded ? "[已下载]" : "[未下载]")")
                                    .tag(model.name)
                            }
                        }
                        .pickerStyle(.menu)

                        if selectedAlignerModel.contains("coreml") {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("当前依赖暂未提供 CoreML ForcedAligner 推理接口；可下载备用，实际生成请先选 MLX 4-bit。")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.stropheSecondaryBackground.opacity(0.5))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.stropheBorder, lineWidth: 1)
                )

                // Section 3: Pyannote Diarization Config
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("对话人识别 (Pyannote)")
                            .font(.headline)
                            .foregroundStyle(Color.stropheText)
                        
                        Spacer()
                        
                        Toggle("", isOn: $enableDiarization)
                            .toggleStyle(.switch)
                            .tint(Color.stropheAccent)
                    }
                    
                    if enableDiarization {
                        VStack(alignment: .leading, spacing: 12) {
                            Divider()
                                .background(Color.stropheBorder)
                            
                            // Speaker Count
                            VStack(alignment: .leading, spacing: 6) {
                                Text("发言人数")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                Picker("", selection: $speakerCountOption) {
                                    Text("自动检测").tag("auto")
                                    Text("指定人数").tag("custom")
                                }
                                .pickerStyle(.segmented)
                                
                                if speakerCountOption == "custom" {
                                    Stepper("发言人数量: \(customSpeakerCount) 人", value: $customSpeakerCount, in: 1...10)
                                        .font(.subheadline)
                                        .foregroundStyle(Color.stropheText)
                                }
                            }
                            
                            // Prefix Speaker name
                            Toggle(isOn: $prefixSpeakerName) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("在字幕行中添加发言人前缀")
                                        .font(.subheadline)
                                    Text("例如: [Speaker 0] 你好，世界。")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkboxIfSupported)
                            .tint(Color.stropheAccent)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.stropheSecondaryBackground.opacity(0.5))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.stropheBorder, lineWidth: 1)
                )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }
    
    // MARK: - Running / Processing State View
    private var runningStateView: some View {
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
                    Text("\(Int(stepProgress * 100))%")
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
    
    // MARK: - Process AI pipeline
    private func startCaptioningProcess() {
        guard let mediaURL = project.videoURL else { return }
        
        isRunning = true
        currentStep = 0
        stepProgress = 0.0
        statusMessage = "正在检查依赖的 AI 模型..."
        
        Task {
            do {
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

                let isAlignerDownloaded = modelManager.downloadedAlignerModels.contains(selectedAlignerModel)
                if !isAlignerDownloaded {
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
                let whisperModelURL: URL
                if let hubDir = modelManager.getModelDirectory(for: selectedModel, type: .whisper) {
                    whisperModelURL = hubDir
                } else {
                    let folderName = LocalModelManager.whisperPresets.first(where: { $0.name == selectedModel })?.folderName ?? selectedModel
                    whisperModelURL = whisperBaseDir.appendingPathComponent(folderName)
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
                
                let modelStorageRoot = modelManager.resolvedExternalURL()
                let generator = SubtitleGenerator()
                let results = try await generator.generateDiarizedSubtitles(
                    audioURL: mediaURL,
                    whisperModelURL: whisperModelURL,
                    alignerModelURL: alignerModelURL,
                    speakerModelURL: speakerModelURL,
                    whisperBaseDir: whisperBaseDir,
                    alignerBaseDir: alignerBaseDir,
                    speakerBaseDir: speakerBaseDir,
                    alignerModelId: alignerModelId,
                    modelStorageRoot: modelStorageRoot,
                    expectedSpeakers: expectedSpeakersCount,
                    language: selectedLanguage,
                    enableDiarization: enableDiarization,
                    prefixSpeakerName: prefixSpeakerName,
                    enableAlignment: true,
                    vocalPreprocessing: vocalPreprocessing,
                    referenceText: referenceLyrics,
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
                
                let generatedSubtitles = results.enumerated().map { index, seg in
                    SubtitleItem(
                        text: cleanSubtitleText(seg.text),
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
    
    private func cleanSubtitleText(_ text: String) -> String {
        var result = text
        
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
extension ToggleStyle where Self == DefaultToggleStyle {
    fileprivate static var checkboxIfSupported: CheckboxToggleStyle { CheckboxToggleStyle() }
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
