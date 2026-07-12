//
//  AutoCaptionView+FormSections.swift
//  Strophe
//
//  Created by Antigravity on 2026/07/12.
//

import SwiftUI

extension AutoCaptionView {

    // MARK: - configurationForm (macOS)

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

    // MARK: - cloudConfigurationForm

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
