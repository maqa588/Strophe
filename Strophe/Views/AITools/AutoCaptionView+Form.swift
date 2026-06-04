//
//  AutoCaptionView+Form.swift
//  Strophe
//
//  Created by Antigravity on 2026/06/04.
//

import SwiftUI

extension AutoCaptionView {
    
    #if !os(macOS)
    @ViewBuilder
    var iosBody: some View {
        NavigationView {
            Form {
                if isRunning {
                    Section {
                        runningStateView
                    }
                } else if !isLocalAISupported {
                    Section {
                        LocalAIUnsupportedView()
                    }

                    Section {
                        HStack {
                            Text("模型选择")
                            Spacer()
                            Text("")
                                .foregroundStyle(.secondary)
                        }
                        .disabled(true)

                        HStack {
                            Text("对齐器模型")
                            Spacer()
                            Text("")
                                .foregroundStyle(.secondary)
                        }
                        .disabled(true)
                    } header: {
                        Text("语音识别配置")
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
                        let alignerControlsEnabled = enableAlignment || enableDiarization
                        Toggle("启用时间轴精修", isOn: $enableAlignment)
                            .tint(Color.stropheAccent)

                        // Aligner Model
                        Picker("对齐器模型", selection: $selectedAlignerModel) {
                            ForEach(LocalModelManager.alignerPresets, id: \.name) { model in
                                let isDownloaded = modelManager.downloadedAlignerModels.contains(model.name)
                                Text("\(model.name) (\(model.size)) \(isDownloaded ? "[已下载]" : "[未下载]")")
                                    .tag(model.name)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .disabled(!alignerControlsEnabled)
                        
                        if !enableAlignment && enableDiarization {
                            Text("对话人识别仍会调用对齐器生成词级时间戳，但不会额外做时间轴精修。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !enableAlignment {
                            Text("关闭后仅使用 VAD 与 Qwen3-ASR 生成粗略时间轴。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if selectedAlignerModel.contains("coreml") {
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
                            handleStartButton()
                        }
                        .fontWeight(.bold)
                        .disabled(isLocalAISupported && project.videoURL == nil)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
    #endif
    
    @ViewBuilder
    var mainContent: some View {
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
            } else if !isLocalAISupported {
                unsupportedConfigurationForm
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
                
                Button(action: handleStartButton) {
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
                .disabled(isRunning || (isLocalAISupported && project.videoURL == nil))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    var unsupportedConfigurationForm: some View {
        ScrollView {
            VStack(spacing: 20) {
                LocalAIUnsupportedView()

                VStack(alignment: .leading, spacing: 12) {
                    Text("语音识别配置")
                        .font(.headline)
                        .foregroundStyle(Color.stropheText)

                    disabledEmptySettingRow(title: "模型选择")
                    disabledEmptySettingRow(title: "对齐器模型")
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

    @ViewBuilder
    private func disabledEmptySettingRow(title: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color.stropheText)
            Spacer()
            Text("")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .opacity(0.55)
        .disabled(true)
    }
    
    @ViewBuilder
    var configurationForm: some View {
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
                    let alignerControlsEnabled = enableAlignment || enableDiarization
                    HStack {
                        Text("强制对齐配置 (Qwen3-ForcedAligner)")
                            .font(.headline)
                            .foregroundStyle(Color.stropheText)

                        Spacer()

                        Toggle("", isOn: $enableAlignment)
                            .toggleStyle(.switch)
                            .tint(Color.stropheAccent)
                    }

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
                        .disabled(!alignerControlsEnabled)

                        if !enableAlignment && enableDiarization {
                            HStack(spacing: 6) {
                                Image(systemName: "person.2.wave.2")
                                    .foregroundStyle(.secondary)
                                Text("对话人识别仍会调用对齐器生成词级时间戳，但不会额外做时间轴精修。")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        } else if !enableAlignment {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.badge.xmark")
                                    .foregroundStyle(.secondary)
                                Text("关闭后仅使用 VAD 与 Qwen3-ASR 生成粗略时间轴。")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        } else if selectedAlignerModel.contains("coreml") {
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
}
