import SwiftUI

extension AutoCaptionView {
    @ViewBuilder
    var simpleConfigurationForm: some View {
        ScrollView {
            VStack(spacing: 20) {
                mediaStatusCard
                if selectedGenerationMode == .cloud {
                    cloudConfigurationForm
                } else if isLocalAISupported {
                    simpleLocalConfigurationCard
                } else {
                    LocalAIUnsupportedView(detail: AIBackendClient.cloudComingSoonMessage)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    var simpleLocalConfigurationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("本地识别", systemImage: "cpu")
                    .font(.headline)
                Spacer()
                Text(areRequiredLocalModelsDownloaded ? "模型已就绪" : "缺少模型")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(areRequiredLocalModelsDownloaded ? Color.stropheAccent : .orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("submission_language")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("submission_language", selection: $selectedLanguage) {
                    ForEach(languages, id: \.0) { item in
                        Text(item.1).tag(item.0)
                    }
                }
                .pickerStyle(.menu)
            }

            Divider()

            Toggle("use_voice_activity_detection", isOn: $useVAD)
                .tint(Color.stropheAccent)

            Text(LocalizedStringKey(useVAD ? "auto_caption_vad_explanation" : "disable_vad_explanation"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !areRequiredLocalModelsDownloaded {
                Divider()
                Text(useVAD ? "本地生成需要先下载 Qwen3-ASR CoreML、ForcedAligner CoreML (FP16 或 INT4) 和 FireRed VAD CoreML。" : "本地生成需要先下载 Qwen3-ASR CoreML 和 ForcedAligner CoreML (FP16 或 INT4)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    if !modelManager.downloadedWhisperModels.contains(LocalModelManager.coreMLASRAccelerationModelName) {
                        Button("下载语音识别模型") { openModelSettings(.whisperConfig) }
                            .buttonStyle(.bordered)
                    }
                    if !modelManager.downloadedAlignerModels.contains(selectedAlignerModel) {
                        Button("下载对齐模型") { openModelSettings(.alignerConfig) }
                            .buttonStyle(.bordered)
                    }
                    if useVAD && !modelManager.downloadedVADModels.contains("firered-vad-coreml") {
                        Button("下载 VAD 模型") { openModelSettings(.vadConfig) }
                            .buttonStyle(.bordered)
                    }
                }
            }

            Text("音频仅在设备上处理，不会上传到服务器。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.stropheSecondaryBackground.opacity(0.5))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.stropheBorder, lineWidth: 1))
    }

    #if !os(macOS)
    @ViewBuilder
    var simpleIOSBody: some View {
        NavigationView {
            Form {
                if isRunning {
                    Section { runningStateView }
                } else if selectedGenerationMode == nil {
                    iosMediaSourceSection
                    iosRecognitionModeGuideSection
                } else if selectedGenerationMode == .cloud {
                    iosMediaSourceSection
                    iosCloudRecognitionSection
                    languageSection
                } else if isLocalAISupported {
                    iosMediaSourceSection
                    languageSection
                    vadSection
                    if !areRequiredLocalModelsDownloaded {
                        Section {
                            Text(useVAD ? "本地生成需要先下载 Qwen3-ASR CoreML、ForcedAligner CoreML (FP16 或 INT4) 和 FireRed VAD CoreML。" : "本地生成需要先下载 Qwen3-ASR CoreML 和 ForcedAligner CoreML (FP16 或 INT4)。")
                                .foregroundStyle(.secondary)
                            if !modelManager.downloadedWhisperModels.contains(LocalModelManager.coreMLASRAccelerationModelName) {
                                Button("下载语音识别模型") { openModelSettings(.whisperConfig) }
                            }
                            if !modelManager.downloadedAlignerModels.contains(selectedAlignerModel) {
                                Button("下载对齐模型") { openModelSettings(.alignerConfig) }
                            }
                            if useVAD && !modelManager.downloadedVADModels.contains("firered-vad-coreml") {
                                Button("下载 VAD 模型") { openModelSettings(.vadConfig) }
                            }
                        } header: { Text("缺少模型") }
                    }
                } else {
                    Section { LocalAIUnsupportedView() }
                }
            }
            .navigationTitle("ai_auto_subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if selectedGenerationMode != nil && !isRunning {
                        Button("back") { selectedGenerationMode = nil }
                    } else {
                        Button("cancel") { dismiss() }.disabled(isRunning)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isRunning {
                        ProgressView()
                    } else if selectedGenerationMode == .local {
                        Button("local") { handleStartLocalButton() }
                            .fontWeight(.bold)
                            .disabled(!canStartLocalCaptioning)
                    } else if selectedGenerationMode == .cloud {
                        Button("cloud") { handleStartCloudButton() }
                            .fontWeight(.bold)
                            .disabled(!canStartCloudCaptioning)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var languageSection: some View {
        Section {
            Picker("submission_language", selection: $selectedLanguage) {
                ForEach(languages, id: \.0) { item in Text(item.1).tag(item.0) }
            }
            .pickerStyle(.navigationLink)
        } header: { Text("language_config") }
    }

    @ViewBuilder
    private var vadSection: some View {
        Section {
            Toggle("use_voice_activity_detection", isOn: $useVAD)
                .tint(Color.stropheAccent)

            Text(LocalizedStringKey(useVAD ? "auto_caption_vad_explanation" : "disable_vad_explanation"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: { Text("voice_activity_detection") }
    }
    #endif

    private func openModelSettings(_ route: SettingsRoute) {
        dismiss()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .stropheOpenModelSettings, object: route)
        }
    }
}
