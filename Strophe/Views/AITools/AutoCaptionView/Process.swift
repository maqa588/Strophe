//
//  AutoCaptionView+Process.swift
//  Strophe
//
//  Created by Antigravity on 2026/06/04.
//

import SwiftUI

extension AutoCaptionView {
    
    @ViewBuilder
    var runningStateView: some View {
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
                    Text(stepProgress, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.stropheText)
                    
                    Text("progress_label")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Steps layout - 对应本地 Golden Pipeline 或云端识别流程
            VStack(alignment: .leading, spacing: 14) {
                let stepTitles = runningStepTitles
                
                ForEach(stepTitles.indices, id: \.self) { index in
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

    var runningStepTitles: [String] {
        func localized(_ key: String) -> String {
            NSLocalizedString(key, comment: "Subtitle generation progress step")
        }
        func step(_ number: Int, _ title: String) -> String {
            String(
                format: localized("process_step_format"),
                number,
                title
            )
        }
        func modelStep(_ number: Int) -> String {
            let task = String(
                format: localized("process_asr_format"),
                LocalModelManager.shortASRDisplayName(selectedModel)
            )
            return step(number, task)
        }

        switch runningMode {
        case .cloud:
            let cloudRecognition = String(
                format: localized("process_cloud_recognize_format"),
                selectedCloudModel.displayName
            )
            return [
                step(1, localized("process_extract_16k_audio")),
                step(2, localized("process_cloud_upload")),
                step(3, cloudRecognition),
                step(4, localized("process_write_timeline"))
            ]
        case .local:
            let preprocessingTitle: String = {
                switch vocalPreprocessing {
                case "none": return step(1, localized("process_extract_audio"))
                case "separate": return step(1, localized("process_separate_vocals"))
                default: return step(1, localized("process_denoise"))
                }
            }()
            if isParakeetJASelected || (!enableAlignment && !generateKaraoke) {
                return [
                    preprocessingTitle,
                    modelStep(2),
                    step(3, localized("process_subtitle_output"))
                ]
            }
            if enableDiarization {
                return [
                    preprocessingTitle,
                    modelStep(2),
                    step(3, localized("process_forced_alignment")),
                    step(4, localized("process_speaker_diarization"))
                ]
            }
            return [
                preprocessingTitle,
                modelStep(2),
                step(3, localized("process_forced_alignment")),
                step(4, localized("process_subtitle_output"))
            ]
        }
    }
    
    // Execution methods are in Process+Execution.swift

    func subtitleItems(
        from results: [AIResultSegment],
        karaokeEnabled: Bool = false
    ) -> [SubtitleItem] {
        results.enumerated().compactMap { index, seg -> SubtitleItem? in
            let cleaned = cleanSubtitleText(seg.text)

            // 去除可能存在的说话人标签后再检查是否为空
            var textWithoutSpeaker = cleaned
            if textWithoutSpeaker.hasPrefix("["), let endBracket = textWithoutSpeaker.firstIndex(of: "]") {
                let startIndex = textWithoutSpeaker.index(after: endBracket)
                textWithoutSpeaker = String(textWithoutSpeaker[startIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // 如果字幕块最终只有“嗯啊呃”或标点符号（即剥离说话人标签后为空），则丢弃该字幕块
            if textWithoutSpeaker.isEmpty {
                return nil
            }

            let alignedKaraoke = KaraokeProgram.fromAlignedWords(
                seg.words,
                cueText: cleaned,
                cueStartTime: seg.startTime,
                cueEndTime: seg.endTime,
                isEnabled: karaokeEnabled
            )
            let karaoke = alignedKaraoke
                ?? (karaokeEnabled
                    ? KaraokeProgram.evenlyTimed(
                        text: cleaned,
                        duration: max(0, seg.endTime - seg.startTime)
                    )
                    : nil)
            return SubtitleItem(
                text: cleaned,
                startTime: seg.startTime,
                endTime: seg.endTime,
                originalIndex: index,
                karaoke: karaoke
            )
        }
    }

    @MainActor
    func replaceProjectSubtitles(with generatedSubtitles: [SubtitleItem], actionName: String) {
        let oldItems = project.items
        let oldSelectedIDs = project.selectedIDs
        project.items = generatedSubtitles
        project.undoManager.registerUndo(withTarget: project) { target in
            target.items = oldItems
            target.selectedIDs = oldSelectedIDs
            target.notifyChange()
        }
        project.undoManager.setActionName(actionName)
        project.currentIndex = 0
        project.notifyChange()
    }

    @MainActor
    func finishSuccessfulGeneration(message: String) {
        stepProgress = 1.0
        statusMessage = message
    }

    @MainActor
    func finishFailedGeneration(_ error: Error) {
        isRunning = false
        generationErrorMessage = error.localizedDescription
        statusMessage = localizedAIFormat(
            "status_generation_failed_format",
            error.localizedDescription
        )
        showGenerationErrorAlert = true
    }
}
