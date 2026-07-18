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
                Label("local_recognition", systemImage: "cpu")
                    .font(.headline)
                Spacer()
                Text(areRequiredLocalModelsDownloaded ? "model_ready" : "missing_model")
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
                Text(useVAD ? "local_generation_missing_models_vad_hint" : "local_generation_missing_models_aligner_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    if !modelManager.downloadedWhisperModels.contains(LocalModelManager.coreMLASRAccelerationModelName) {
                        Button("download_asr_model") { openModelSettings(.whisperConfig) }
                            .buttonStyle(.bordered)
                    }
                    if !modelManager.downloadedAlignerModels.contains(selectedAlignerModel) {
                        Button("download_align_model") { openModelSettings(.alignerConfig) }
                            .buttonStyle(.bordered)
                    }
                    if useVAD && !modelManager.downloadedVADModels.contains("firered-vad-coreml") {
                        Button("download_vad_model") { openModelSettings(.vadConfig) }
                            .buttonStyle(.bordered)
                    }
                }
            }

            Text("audio_processed_locally_hint")
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
                            Text(useVAD ? "local_generation_missing_models_vad_hint" : "local_generation_missing_models_aligner_hint")
                                .foregroundStyle(.secondary)
                            if !modelManager.downloadedWhisperModels.contains(LocalModelManager.coreMLASRAccelerationModelName) {
                                Button("download_asr_model") { openModelSettings(.whisperConfig) }
                            }
                            if !modelManager.downloadedAlignerModels.contains(selectedAlignerModel) {
                                Button("download_align_model") { openModelSettings(.alignerConfig) }
                            }
                            if useVAD && !modelManager.downloadedVADModels.contains("firered-vad-coreml") {
                                Button("download_vad_model") { openModelSettings(.vadConfig) }
                            }
                        } header: { Text("missing_model") }
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
