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

    var runningStepTitles: [String] {
        switch runningMode {
        case .cloud:
            return [
                "第一步: 提取 16k 音频...",
                "第二步: 上传云端服务...",
                "第三步: 云端识别与对齐...",
                "第四步: 写入字幕时间轴..."
            ]
        case .local:
            let preprocessingTitle: String = {
                switch vocalPreprocessing {
                case "none": return "第一步: 提取音频..."
                case "separate": return "第一步: 伴奏人声分离 (Spleeter)..."
                default: return "第一步: 智能降噪 (DeepFilterNet3)..."
                }
            }()
            if enableDiarization {
                return [
                    preprocessingTitle,
                    "第二步: 语音识别转写 (Qwen3-ASR)...",
                    "第三步: 毫秒级字词对齐 (ForcedAligner)...",
                    "第四步: 发言角色声纹分离 (Pyannote)..."
                ]
            }
            return [
                preprocessingTitle,
                "第二步: 语音识别转写 (Qwen3-ASR)...",
                "第三步: 毫秒级字词对齐 (ForcedAligner)...",
                "第四步: 字幕片段整合输出..."
            ]
        }
    }
    
    // Execution methods are in Process+Execution.swift

    func subtitleItems(from results: [AIResultSegment]) -> [SubtitleItem] {
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

            return SubtitleItem(
                text: cleaned,
                startTime: seg.startTime,
                endTime: seg.endTime,
                originalIndex: index
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
        statusMessage = "生成失败: \(error.localizedDescription)"
        showGenerationErrorAlert = true
    }
}
