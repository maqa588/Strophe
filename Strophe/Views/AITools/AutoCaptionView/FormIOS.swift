//
//  AutoCaptionView+Form+iOS.swift
//  Strophe
//
//  Created by Antigravity on 2026/06/04.
//

import SwiftUI

#if !os(macOS)
extension AutoCaptionView {
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
                        Picker("cloud_model_selection", selection: $selectedCloudModel) {
                            ForEach(orderedCloudModels) { model in
                                Text(cloudModelPickerTitle(model))
                                    .tag(model)
                            }
                        }
                        .pickerStyle(.navigationLink)

                        Picker("submission_language", selection: $selectedLanguage) {
                            ForEach(languages, id: \.0) { item in
                                Text(LocalizedStringKey(item.1)).tag(item.0)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .disabled(isCloudParakeetJASelected)
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
                            ForEach(availableASRModels, id: \.name) { model in
                                Text(modelPickerTitle(model))
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
                                Text(LocalizedStringKey(item.1)).tag(item.0)
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
                                Text(auxiliaryModelPickerTitle(model, downloaded: isDownloaded))
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
                            Text("coreml_aligner_enabled_format \(precision)")
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
                                Stepper("speaker_count_format \(customSpeakerCount)", value: $customSpeakerCount, in: 1...10)
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
                    Text("current_media_format \(project.documentDisplayName)")
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
            TextField(
                AIBackendClient.defaultCloudBaseURL.absoluteString,
                text: $cloudBaseURLString
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(cloudConnectionTestState == .testing)
            .stropheOnChange(of: cloudBaseURLString) { _ in
                if cloudConnectionTestState != .testing {
                    cloudConnectionTestState = .idle
                }
            }

            Button(action: handleTestCloudConnection) {
                HStack {
                    Label("test_connection", systemImage: "network")
                    if cloudConnectionTestState == .testing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(cloudConnectionTestState == .testing || configuredCloudBaseURL == nil)

            cloudConnectionStatusView

            HStack {
                Text("subtitle_mode")
                Spacer()
                Text("full_sentence")
                    .foregroundStyle(.secondary)
            }

            Toggle("generate_karaoke_subtitles", isOn: $generateKaraoke)
                .tint(Color.stropheAccent)

            Text("generate_karaoke_subtitles_explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("cloud_recognition")
        }
        .onAppear(perform: triggerCloudLocalNetworkPermission)
    }

    @ViewBuilder
    var iosRecognitionModeGuideSection: some View {
        Section {
            Button {
                handleChooseCloudButton()
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
}
#endif
