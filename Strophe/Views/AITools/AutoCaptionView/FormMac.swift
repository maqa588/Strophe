//
//  AutoCaptionView+Form+Mac.swift
//  Strophe
//
//  Created by Antigravity on 2026/06/04.
//

import SwiftUI

#if os(macOS)
extension AutoCaptionView {
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
}
#endif
