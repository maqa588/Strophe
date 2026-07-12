//
//  AutoCaptionView+Form.swift
//  Strophe
//
//  Created by Antigravity on 2026/06/04.
//

import SwiftUI

extension AutoCaptionView {
    var coreMLASRAccelerationBinding: Binding<Bool> {
        Binding(
            get: {
                enableCoreMLASRAcceleration && LocalModelManager.supportsCoreMLASRAcceleration(selectedModel)
            },
            set: { newValue in
                enableCoreMLASRAcceleration = newValue
            }
        )
    }
    
    #if !os(macOS)
    @ViewBuilder
    var iosBody: some View {
        NavigationView {
            Form {
                if isRunning {
                    Section {
                        runningStateView
                    }
                } else if selectedGenerationMode == nil {
                    iosMediaSourceSection
                    iosRecognitionModeGuideSection
                } else if selectedGenerationMode == .cloud {
                    iosMediaSourceSection
                    iosCloudRecognitionSection
                    Section {
                        Picker("submission_language", selection: $selectedLanguage) {
                            ForEach(languages, id: \.0) { item in
                                Text(item.1).tag(item.0)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    } header: {
                        Text("language_config")
                    } footer: {
                        Text("recommend_specific_language_explanation")
                    }
                } else if !isLocalAISupported {
                    iosMediaSourceSection

                    if isLocalAIIncludedInBuild {
                        Section {
                            LocalAIUnsupportedView()
                        }

                        Section {
                            HStack {
                                Text("model_selection")
                                Spacer()
                                Text("")
                                    .foregroundStyle(.secondary)
                            }
                            .disabled(true)

                            HStack {
                                Text("aligner_model")
                                Spacer()
                                Text("")
                                    .foregroundStyle(.secondary)
                            }
                            .disabled(true)
                        } header: {
                            Text("local_speech_recognition_config")
                        }
                    }
                } else {
                    iosMediaSourceSection
                    
                    Section {
                        // Model Selection
                        Picker("model_selection", selection: $selectedModel) {
                            ForEach(LocalModelManager.whisperPresets, id: \.name) { model in
                                let isDownloaded = modelManager.downloadedWhisperModels.contains(model.name)
                                Text("\(model.name) (\(model.size)) \(isDownloaded ? "[已下载]" : "[未下载]")")
                                    .tag(model.name)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        
                        let isSelectedDownloaded = modelManager.downloadedWhisperModels.contains(selectedModel)
                        if !isSelectedDownloaded {
                            Text("note_this_model_has_not")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Toggle("enable_coreml_encoder_acceleration", isOn: coreMLASRAccelerationBinding)
                            .tint(Color.stropheAccent)
                            .disabled(!LocalModelManager.supportsCoreMLASRAcceleration(selectedModel))

                        if enableCoreMLASRAcceleration && LocalModelManager.supportsCoreMLASRAcceleration(selectedModel) {
                            let isCoreMLDownloaded = modelManager.downloadedWhisperModels.contains(LocalModelManager.coreMLASRAccelerationModelName)
                            Text(isCoreMLDownloaded ? "coreml_encoder_downloaded" : "coreml_encoder_not_downloaded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !LocalModelManager.supportsCoreMLASRAcceleration(selectedModel) {
                            Text("coreml_compatibility_explanation")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        // Language Selection
                        Picker("recognition_language", selection: $selectedLanguage) {
                            ForEach(languages, id: \.0) { item in
                                Text(item.1).tag(item.0)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        
                        // Preprocessing Selection
                        VStack(alignment: .leading, spacing: 6) {
                            Text("vocal_preprocessing")
                                .font(.subheadline)
                            Picker("preprocessing", selection: $vocalPreprocessing) {
                                Text("do_not_process").tag("none")
                                Text("smart_noise_reduction").tag("denoise")
                                Text("vocal_separation").tag("separate")
                            }
                            .pickerStyle(.segmented)
                            .disabled(true)
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("speech_recognition_config_qwen3_asr")
                    }
                    
                    Section {
                        Toggle("use_voice_activity_detection", isOn: $useVAD)
                            .tint(Color.stropheAccent)
                        
                        Text(LocalizedStringKey(useVAD ? "auto_caption_vad_explanation" : "disable_vad_explanation"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("voice_activity_detection")
                    }
                    
                    Section {
                        let alignerControlsEnabled = enableAlignment || enableDiarization
                        Toggle("enable_timeline_refinement", isOn: $enableAlignment)
                            .tint(Color.stropheAccent)

                        // Aligner Model
                        Picker("aligner_model", selection: $selectedAlignerModel) {
                            ForEach(LocalModelManager.alignerPresets, id: \.name) { model in
                                let isDownloaded = modelManager.downloadedAlignerModels.contains(model.name)
                                Text("\(model.name) (\(model.size)) \(isDownloaded ? "[已下载]" : "[未下载]")")
                                    .tag(model.name)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .disabled(!alignerControlsEnabled)
                        
                        if !enableAlignment && enableDiarization {
                            Text("speaker_diarization_aligner_explanation")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !enableAlignment {
                            Text("close_vad_explanation")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if selectedAlignerModel.contains("coreml") {
                            let precision = "INT8"
                            Text("CoreML \(precision) 对齐器已启用")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("forced_alignment_config_qwen3_forcedaligner")
                    }
                    
                    Section {
                        Toggle("enable_speaker_diarization_pyannote", isOn: $enableDiarization)
                            .tint(Color.stropheAccent)
                            .disabled(true)
                        
                        if enableDiarization {
                            Picker("number_of_speakers", selection: $speakerCountOption) {
                                Text("auto_detect").tag("auto")
                                Text("specify_number_of_people").tag("custom")
                            }
                            .pickerStyle(.segmented)
                            
                            if speakerCountOption == "custom" {
                                Stepper("发言人数量: \(customSpeakerCount) 人", value: $customSpeakerCount, in: 1...10)
                            }
                            
                            Toggle("add_speaker_prefix_in_subtitles", isOn: $prefixSpeakerName)
                                .tint(Color.stropheAccent)
                        }
                    } header: {
                        Text("speaker_diarization")
                    }
                    
                    Section {
                        TextEditor(text: $referenceLyrics)
                            .frame(minHeight: 100)
                            .font(.system(.body, design: .rounded))
                    } header: {
                        Text("reference_lyrics_optional")
                    } footer: {
                        Text("for_songs_it_is_recommended")
                    }
                }
            }
            .navigationTitle("ai_auto_subtitles")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if (selectedGenerationMode == .local || selectedGenerationMode == .cloud) && !isRunning {
                        Button("back") {
                            selectedGenerationMode = nil
                        }
                    } else {
                        Button("cancel") {
                            dismiss()
                        }
                        .disabled(isRunning)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isRunning {
                        ProgressView()
                    } else if selectedGenerationMode == .local {
                        Button("local") {
                            handleStartLocalButton()
                        }
                        .fontWeight(.bold)
                        .disabled(!canStartLocalCaptioning)
                    } else if selectedGenerationMode == .cloud {
                        Button("cloud") {
                            handleStartCloudButton()
                        }
                        .fontWeight(.bold)
                        .disabled(!canStartCloudCaptioning)
                    } else {
                        EmptyView()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    var iosMediaSourceSection: some View {
        Section {
            if project.videoURL == nil {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.title2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("no_media_loaded_1")
                            .fontWeight(.semibold)
                        Text("please_import_a_video_or")
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
    }

    @ViewBuilder
    var iosCloudRecognitionSection: some View {
        Section {
            HStack {
                Label("server_address", systemImage: "cloud")
                Spacer()
                Text(AIBackendClient.defaultCloudBaseURL.absoluteString)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack {
                Text("subtitle_mode")
                Spacer()
                Text("full_sentence")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("cloud_recognition")
        }
    }

    @ViewBuilder
    var iosRecognitionModeGuideSection: some View {
        Section {
            Button {
                selectedGenerationMode = .cloud
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("cloud_recognition", systemImage: "cloud.fill")
                            .font(.headline)
                        Spacer()
                        Text(LocalizedStringKey(project.videoURL == nil ? "media_required" : "available"))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(project.videoURL == nil ? .secondary : Color.stropheAccent)
                    }
                    Text(cloudRecognitionDetailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canStartCloudCaptioning)

            Button {
                handleChooseLocalButton()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("local_recognition", systemImage: "cpu")
                            .font(.headline)
                        Spacer()
                        Text(LocalizedStringKey(project.videoURL == nil ? "media_required" : localRecognitionStatusText))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle((isLocalAIIncludedInBuild && isLocalAISupported && project.videoURL != nil) ? Color.stropheAccent : .secondary)
                    }
                    Text(localRecognitionDetailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!isLocalAIIncludedInBuild || !isLocalAISupported || project.videoURL == nil)
        } header: {
            Text("select_recognition_method")
        } footer: {
            Text("config_required_for_recognition")
        }
    }
    #endif
    
    @ViewBuilder
    var mainContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("ai_auto_subtitles")
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
            } else if selectedGenerationMode == nil {
                recognitionModeGuide
            } else {
                simpleConfigurationForm
            }
            
            Divider()
                .background(Color.stropheBorder)
            
            // Bottom Actions
            HStack {
                if (selectedGenerationMode == .local || selectedGenerationMode == .cloud) && !isRunning {
                    Button("back") {
                        selectedGenerationMode = nil
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.stropheText)
                }

                Spacer()

                Button("cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(isRunning)
                .tint(Color.stropheText)

                if selectedGenerationMode == .local {
                    Button(action: handleStartLocalButton) {
                        Text("local_generate_subtitles")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.stropheAccent)
                    .disabled(!canStartLocalCaptioning)
                } else if selectedGenerationMode == .cloud {
                    Button(action: handleStartCloudButton) {
                        Text("cloud_generate_subtitles")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.stropheAccent)
                    .disabled(!canStartCloudCaptioning)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    var recognitionModeGuide: some View {
        ScrollView {
            VStack(spacing: 18) {
                mediaStatusCard

                Text("select_recognition_method")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.stropheText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: { selectedGenerationMode = .cloud }) {
                    recognitionChoiceCard(
                        title: "cloud_recognition",
                        systemImage: "cloud.fill",
                        status: project.videoURL == nil ? "media_required" : "available",
                        detail: cloudRecognitionDetailText,
                        isProminent: true,
                        isAvailable: project.videoURL != nil
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canStartCloudCaptioning)

                Button(action: handleChooseLocalButton) {
                    recognitionChoiceCard(
                        title: "local_recognition",
                        systemImage: "cpu",
                        status: project.videoURL == nil ? "media_required" : localRecognitionStatusText,
                        detail: localRecognitionDetailText,
                        isProminent: false,
                        isAvailable: isLocalAIIncludedInBuild && isLocalAISupported && project.videoURL != nil
                    )
                }
                .buttonStyle(.plain)
                .disabled(!isLocalAIIncludedInBuild || !isLocalAISupported || project.videoURL == nil)

                Text("config_required_for_recognition")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
    }

    @ViewBuilder
    func recognitionChoiceCard(
        title: String,
        systemImage: String,
        status: String,
        detail: String,
        isProminent: Bool,
        isAvailable: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isProminent && isAvailable ? Color.stropheAccent : .secondary)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(LocalizedStringKey(title))
                        .font(.headline)
                        .foregroundStyle(Color.stropheText)

                    Spacer()

                    Text(LocalizedStringKey(status))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(isAvailable ? Color.stropheAccent : .secondary)
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.stropheSecondaryBackground.opacity(isProminent ? 0.7 : 0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isProminent && isAvailable ? Color.stropheAccent.opacity(0.55) : Color.stropheBorder, lineWidth: 1)
        )
        .opacity(isAvailable ? 1.0 : 0.62)
    }

    @ViewBuilder
    var cloudConfigurationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("cloud_recognition", systemImage: "cloud")
                    .font(.headline)
                    .foregroundStyle(Color.stropheText)

                Spacer()

                Text("available")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.stropheAccent)
            }

            HStack {
                Text("server_address")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(AIBackendClient.defaultCloudBaseURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(Color.stropheText)
                    .lineLimit(1)
            }

            HStack {
                Text("subtitle_mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("full_sentence")
                    .font(.caption)
                    .foregroundStyle(Color.stropheText)
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

    @ViewBuilder
    var mediaStatusCard: some View {
        if project.videoURL == nil {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("no_media_loaded_1")
                        .fontWeight(.semibold)
                    Text("please_import_a_video_or")
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
    }
    
    @ViewBuilder
    var configurationForm: some View {
        ScrollView {
            VStack(spacing: 20) {
                mediaStatusCard

                if selectedGenerationMode == .cloud {
                    cloudConfigurationForm
                } else if isLocalAIIncludedInBuild {
                    if isLocalAISupported {
                
                        // Section 1: Qwen3-ASR Config
                        VStack(alignment: .leading, spacing: 12) {
                            Text("speech_recognition_config_qwen3_asr")
                        .font(.headline)
                        .foregroundStyle(Color.stropheText)
                    
                    // Model Selection
                    VStack(alignment: .leading, spacing: 6) {
                        Text("model_selection")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Picker("model", selection: $selectedModel) {
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
                                Text("note_this_model_has_not")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("enable_coreml_encoder_acceleration", isOn: coreMLASRAccelerationBinding)
                                .toggleStyle(.switch)
                                .tint(Color.stropheAccent)
                                .disabled(!LocalModelManager.supportsCoreMLASRAcceleration(selectedModel))

                            if enableCoreMLASRAcceleration && LocalModelManager.supportsCoreMLASRAcceleration(selectedModel) {
                                let isCoreMLDownloaded = modelManager.downloadedWhisperModels.contains(LocalModelManager.coreMLASRAccelerationModelName)
                                HStack(spacing: 6) {
                                    Image(systemName: "cpu")
                                        .foregroundStyle(.secondary)
                                    Text(isCoreMLDownloaded ? "coreml_encoder_downloaded" : "coreml_encoder_not_downloaded")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            } else if !LocalModelManager.supportsCoreMLASRAcceleration(selectedModel) {
                                HStack(spacing: 6) {
                                    Image(systemName: "info.circle.fill")
                                        .foregroundStyle(.secondary)
                                    Text("coreml_compatibility_explanation")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                    
                    // Language Selection
                    VStack(alignment: .leading, spacing: 6) {
                        Text("recognition_language")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Picker("recognition_language", selection: $selectedLanguage) {
                            ForEach(languages, id: \.0) { item in
                                Text(item.1).tag(item.0)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Preprocessing Selection
                    VStack(alignment: .leading, spacing: 6) {
                        Text("vocal_preprocessing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Picker("preprocessing", selection: $vocalPreprocessing) {
                            Text("quiet_vocals_no_processing").tag("none")
                            Text("noisy_vocals_smart_noise_reduction").tag("denoise")
                            Text("background_music_vocal_separation").tag("separate")
                        }
                        .pickerStyle(.segmented)
                        .disabled(true)
                    }
                    .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("reference_lyrics_optional")
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

                        Text("for_songs_it_is_recommended")
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
                
                // Section 1.5: Voice Activity Detection (VAD) Config
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("voice_activity_detection")
                            .font(.headline)
                            .foregroundStyle(Color.stropheText)

                        Spacer()

                        Toggle("", isOn: $useVAD)
                            .toggleStyle(.switch)
                            .tint(Color.stropheAccent)
                    }

                    Text(LocalizedStringKey(useVAD ? "auto_caption_vad_explanation" : "disable_vad_explanation"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                        Text("forced_alignment_config_qwen3_forcedaligner")
                            .font(.headline)
                            .foregroundStyle(Color.stropheText)

                        Spacer()

                        Toggle("", isOn: $enableAlignment)
                            .toggleStyle(.switch)
                            .tint(Color.stropheAccent)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("aligner_model")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("aligner_model", selection: $selectedAlignerModel) {
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
                                Text("speaker_diarization_aligner_explanation")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        } else if !enableAlignment {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.badge.xmark")
                                    .foregroundStyle(.secondary)
                                Text("close_vad_explanation")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        } else if selectedAlignerModel.contains("coreml") {
                            let precision = "INT8"
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.stropheAccent)
                                Text("CoreML \(precision) 对齐器已启用")
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
                        Text("speaker_diarization_pyannote")
                            .font(.headline)
                            .foregroundStyle(Color.stropheText)
                        
                        Spacer()
                        
                        Toggle("", isOn: $enableDiarization)
                            .toggleStyle(.switch)
                            .tint(Color.stropheAccent)
                            .disabled(true)
                    }
                    
                    if enableDiarization {
                        VStack(alignment: .leading, spacing: 12) {
                            Divider()
                                .background(Color.stropheBorder)
                            
                            // Speaker Count
                            VStack(alignment: .leading, spacing: 6) {
                                Text("number_of_speakers")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                Picker("", selection: $speakerCountOption) {
                                    Text("auto_detect").tag("auto")
                                    Text("specify_number_of_people").tag("custom")
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
                                    Text("add_speaker_prefix_to_subtitle")
                                        .font(.subheadline)
                                    Text("example_speaker_0_hello_world")
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
                    } else {
                        LocalAIUnsupportedView(detail: AIBackendClient.cloudComingSoonMessage)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    var cloudConfigurationForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("cloud_speech_recognition_config")
                .font(.headline)
                .foregroundStyle(Color.stropheText)

            cloudConfigurationCard

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
            .padding(.top, 4)
            
            Text("tip_recommend_specific_language_explanation")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
}
