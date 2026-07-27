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
                Text("model_selection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("model_selection", selection: $selectedModel) {
                    ForEach(availableASRModels, id: \.name) { model in
                        Text(modelPickerTitle(model))
                        .tag(model.name)
                    }
                }
                .pickerStyle(.menu)

                if let model = LocalModelManager.whisperPresets.first(
                    where: { $0.name == selectedModel }
                ) {
                    Text(model.localizedDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if isParakeetJASelected {
                    Label(
                        "parakeet_native_timestamps_hint",
                        systemImage: "waveform.badge.checkmark"
                    )
                        .font(.system(size: 11))
                        .foregroundStyle(Color.stropheAccent)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("submission_language")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("submission_language", selection: $selectedLanguage) {
                    ForEach(languages, id: \.0) { item in
                        Text(LocalizedStringKey(item.1)).tag(item.0)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isParakeetJASelected)
            }

            Divider()

            Toggle("use_voice_activity_detection", isOn: $useVAD)
                .tint(Color.stropheAccent)

            Text(
                LocalizedStringKey(
                    useVAD ? localVADExplanationKey : "disable_vad_explanation"
                )
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !areRequiredLocalModelsDownloaded {
                Divider()
                Text(LocalizedStringKey(localMissingModelsHintKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    if !modelManager.downloadedWhisperModels.contains(selectedModel) {
                        Button("download_asr_model") { openModelSettings(.whisperConfig) }
                            .buttonStyle(.bordered)
                    }
                    if !LocalModelManager.usesNativeTimestamps(selectedModel)
                        && !modelManager.downloadedAlignerModels.contains(selectedAlignerModel) {
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
                    cloudModelSelectionSection
                    languageSection
                } else if isLocalAISupported {
                    iosMediaSourceSection
                    modelSelectionSection
                    languageSection
                    vadSection
                    if !areRequiredLocalModelsDownloaded {
                        Section {
                            Text(LocalizedStringKey(localMissingModelsHintKey))
                                .foregroundStyle(.secondary)
                            if !modelManager.downloadedWhisperModels.contains(selectedModel) {
                                Button("download_asr_model") { openModelSettings(.whisperConfig) }
                            }
                            if !LocalModelManager.usesNativeTimestamps(selectedModel)
                                && !modelManager.downloadedAlignerModels.contains(selectedAlignerModel) {
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
    private var cloudModelSelectionSection: some View {
        Section {
            Picker("cloud_model_selection", selection: $selectedCloudModel) {
                ForEach(orderedCloudModels) { model in
                    Text(cloudModelPickerTitle(model))
                        .tag(model)
                }
            }
            .pickerStyle(.navigationLink)

            Text(LocalizedStringKey(selectedCloudModel.descriptionKey))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("cloud_model_selection")
        }
    }

    @ViewBuilder
    private var modelSelectionSection: some View {
        Section {
            Picker("model_selection", selection: $selectedModel) {
                ForEach(availableASRModels, id: \.name) { model in
                    Text(modelPickerTitle(model))
                        .tag(model.name)
                }
            }
            .pickerStyle(.navigationLink)

            if let model = LocalModelManager.whisperPresets.first(
                where: { $0.name == selectedModel }
            ) {
                Text(model.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isParakeetJASelected {
                Label(
                    "parakeet_native_timestamps_hint",
                    systemImage: "waveform.badge.checkmark"
                )
                .font(.caption)
                .foregroundStyle(Color.stropheAccent)
            }
        } header: {
            Text("model_selection")
        }
    }

    @ViewBuilder
    private var languageSection: some View {
        Section {
            Picker("submission_language", selection: $selectedLanguage) {
                ForEach(languages, id: \.0) {
                    item in Text(LocalizedStringKey(item.1)).tag(item.0)
                }
            }
            .pickerStyle(.navigationLink)
            .disabled(isCurrentRecognitionJapaneseOnly)
        } header: { Text("language_config") }
        footer: {
            if isCurrentRecognitionJapaneseOnly {
                Text("parakeet_japanese_locked_hint")
            }
        }
    }

    @ViewBuilder
    private var vadSection: some View {
        Section {
            Toggle("use_voice_activity_detection", isOn: $useVAD)
                .tint(Color.stropheAccent)

            Text(
                LocalizedStringKey(
                    useVAD ? localVADExplanationKey : "disable_vad_explanation"
                )
            )
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
