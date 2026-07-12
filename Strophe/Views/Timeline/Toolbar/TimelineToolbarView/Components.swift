//
//  TimelineToolbarView.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/17.
//

import SwiftUI
import Combine
#if os(iOS)
import UIKit
#endif

/// 时间轴上方独立的自定义功能工具栏
extension TimelineToolbarView {
    // MARK: - Extracted Components
    
    @ViewBuilder
    var mediaInfoSection: some View {
        HStack(spacing: 6) {
            if !isVeryCompact {
                Image(systemName: "waveform")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            
            if videoURL != nil {
                if isAudioOnly {
                    let sampleRate = waveformData?.sampleRate ?? 44100.0
                    let khz = sampleRate / 1000.0
                    let isWhole = abs(khz - khz.rounded()) < 0.001
                    let rateString = isWhole ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
                    
                    Text(rateString)
                        .timelineInfoBadge(isCompact: isVeryCompact)
                } else {
                    let displayFPS = videoFrameRate
                    let fpsString: String = {
                        if abs(displayFPS - 23.976) < 0.001 {
                            return "23.976 fps"
                        } else if abs(displayFPS - 29.97) < 0.001 {
                            return "29.97 fps"
                        } else if abs(displayFPS - 59.94) < 0.001 {
                            return "59.94 fps"
                        } else {
                            let isWhole = abs(displayFPS - displayFPS.rounded()) < 0.001
                            return isWhole ? "\(Int(displayFPS.rounded())) fps" : String(format: "%.3f fps", displayFPS)
                        }
                    }()
                    
                    Text(fpsString)
                        .timelineInfoBadge(isCompact: isVeryCompact)
                }

                TimelineView(.animation) { timeline in
                    Text(formatPreciseTime(displayTimelineTime(at: timeline.date)))
                        .timelineInfoBadge(
                            foreground: Color.secondary,
                            background: Color.primary.opacity(0.08),
                            isCompact: isVeryCompact
                        )
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    func displayTimelineTime(at date: Date) -> Double {
        let rawTime: Double
        if project.playbackRate == 0 {
            rawTime = project.currentTime
        } else {
            rawTime = project.referenceTime + date.timeIntervalSince(project.referenceDate) * project.playbackRate
        }
        let duration = project.activeEngine?.duration ?? waveformData?.duration ?? rawTime
        let maxTime = duration.isFinite && duration > 0 ? duration : max(rawTime, 0)
        return rawTime.clampedFinite(to: 0...maxTime)
    }

    func formatPreciseTime(_ time: Double) -> String {
        let safeTime = time.isFinite ? max(0, time) : 0
        let totalMilliseconds = Int((safeTime * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }
    
    @ViewBuilder
    var playbackControls: some View {
        if #available(anyAppleOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 0) {
                    Button(action: { project.undo() }) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.stropheAccent)
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive())
                    .help(String(localized: "undo"))

                    BoundarySeekButton(icon: "gobackward", direction: .left, project: project)
                        .glassEffect(.regular.interactive())
                    
                    Button(action: { project.togglePlayback() }) {
                        Image(systemName: playbackRate > 0 ? "pause.fill" : "play.fill")
                            .font(.body.weight(.bold))
                            .foregroundStyle(Color.stropheAccent)
                            .frame(width: 36, height: 28)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive())

                    BoundarySeekButton(icon: "goforward", direction: .right, project: project)
                        .glassEffect(.regular.interactive())

                    Button(action: { project.redo() }) {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.stropheAccent)
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive())
                    .help(String(localized: "redo"))

                    Menu {
                        ForEach([0.5, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                            Button(action: { project.changePlaybackSpeed(speed) }) {
                                HStack {
                                    Text(String(format: "%.2fx", speed))
                                    if targetSpeed == speed { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        Text(String(format: "%.1fx", targetSpeed))
                            .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                            .frame(width: 44, height: 28)
                    }
                    .menuStyle(.button)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
        } else {
            PlaybackControlsLegacy(
                project: project,
                targetSpeed: targetSpeed,
                playbackRate: playbackRate
            )
        }
    }
    
    @ViewBuilder
    var editingModeControls: some View {
        if #available(anyAppleOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 0) {
                    // ── 切分按钮 ──
                    Button(action: { handleSplitAction() }) {
                        Image(systemName: "scissors")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive())
                    .popover(isPresented: $showSplitTip, arrowEdge: .top) {
                        RichTooltipView(icon: "scissors", title: String(localized: "split_subtitles"), message: String(localized: "use_the_playhead_as_the"))
                    }
                    .highPriorityGesture(LongPressGesture(minimumDuration: 0.3).onEnded { _ in
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        showSplitTip = true
                    })
                    .onHover { hovering in
                        splitHoverTask?.cancel()
                        if hovering {
                            splitHoverTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                if !Task.isCancelled { showSplitTip = true }
                            }
                        } else { showSplitTip = false }
                    }

                    // ── 合并按钮 ──
                    Button(action: { handleMergeAction() }) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive())
                    .popover(isPresented: $showMergeTip, arrowEdge: .top) {
                        RichTooltipView(icon: "arrow.down.right.and.arrow.up.left", title: String(localized: "merge_subtitles"), message: String(localized: "merge_the_selected_consecutive_subtitle"))
                    }
                    .highPriorityGesture(LongPressGesture(minimumDuration: 0.3).onEnded { _ in
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        showMergeTip = true
                    })
                    .onHover { hovering in
                        mergeHoverTask?.cancel()
                        if hovering {
                            mergeHoverTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                if !Task.isCancelled { showMergeTip = true }
                            }
                        } else { showMergeTip = false }
                    }

                    // ── 软字幕预览按钮 ──
                    Button(action: { project.showSoftSubtitles.toggle() }) {
                        Image(systemName: showSoftSubtitles ? "captions.bubble.fill" : "captions.bubble")
                            .font(.body.weight(.medium))
                            .foregroundStyle(showSoftSubtitles ? Color.stropheAccent : .primary)
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcutIf(!isEditingText, "s", modifiers: [.option])
                    .glassEffect(.regular.interactive())
                    .popover(isPresented: $showSoftSubtitlesTip, arrowEdge: .top) {
                        RichTooltipView(icon: "captions.bubble", title: String(localized: "soft_subtitle_preview"), message: String(localized: "click_to_toggle_real_time"))
                    }
                    .highPriorityGesture(LongPressGesture(minimumDuration: 0.3).onEnded { _ in
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        showSoftSubtitlesTip = true
                    })
                    .onHover { hovering in
                        softSubtitlesHoverTask?.cancel()
                        if hovering {
                            softSubtitlesHoverTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                if !Task.isCancelled { showSoftSubtitlesTip = true }
                            }
                        } else { showSoftSubtitlesTip = false }
                    }

                    // ── 硬字幕预览按钮 ──
                    Button(action: { project.showHardSubtitles.toggle() }) {
                        Image(systemName: "list.and.film")
                            .font(.body.weight(.medium))
                            .foregroundStyle(showHardSubtitles ? Color.stropheAccent : .primary)
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive())
                    .popover(isPresented: $showHardSubtitlesTip, arrowEdge: .top) {
                        RichTooltipView(icon: "list.and.film", title: String(localized: "hard_subtitle_preview"), message: String(localized: "click_to_turn_onoff_the"))
                    }
                    .highPriorityGesture(LongPressGesture(minimumDuration: 0.3).onEnded { _ in
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        showHardSubtitlesTip = true
                    })
                    .onHover { hovering in
                        hardSubtitlesHoverTask?.cancel()
                        if hovering {
                            hardSubtitlesHoverTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                if !Task.isCancelled { showHardSubtitlesTip = true }
                            }
                        } else { showHardSubtitlesTip = false }
                    }

                    Button(action: { project.editingMode = .selection }) {
                        Image(systemName: "cursorarrow")
                            .font(.body.weight(.medium))
                            .foregroundStyle(editingMode == .selection ? Color.stropheAccent : .primary)
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcutIf(!isEditingText, "v", modifiers: [])
                    .glassEffect(.regular.interactive())
                    .popover(isPresented: $showSelectionTip, arrowEdge: .top) {
                        RichTooltipView(icon: "cursorarrow", title: String(localized: "selection_tool"), message: String(localized: "edit_script_text_drag_timeline"))
                    }
                    .highPriorityGesture(LongPressGesture(minimumDuration: 0.3).onEnded { _ in
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        showSelectionTip = true
                    })
                    .onHover { hovering in
                        selectionHoverTask?.cancel()
                        if hovering {
                            selectionHoverTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                if !Task.isCancelled { showSelectionTip = true }
                            }
                        } else { showSelectionTip = false }
                    }

                    Button(action: { project.editingMode = .creation }) {
                        Image(systemName: "hand.draw")
                            .font(.body.weight(.medium))
                            .foregroundStyle(editingMode == .creation ? Color.stropheAccent : .primary)
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcutIf(!isEditingText, "d", modifiers: [])
                    .glassEffect(.regular.interactive())
                    .popover(isPresented: $showCreationTip, arrowEdge: .top) {
                        RichTooltipView(icon: "hand.draw", title: String(localized: "quick_creation_slap_tool"), message: String(localized: "drag_timeline_to_create_subtitle"))
                    }
                    .highPriorityGesture(LongPressGesture(minimumDuration: 0.3).onEnded { _ in
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        showCreationTip = true
                    })
                    .onHover { hovering in
                        creationHoverTask?.cancel()
                        if hovering {
                            creationHoverTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                if !Task.isCancelled { showCreationTip = true }
                            }
                        } else { showCreationTip = false }
                    }
                }
            }
        } else {
            EditingModeControlsLegacy(
                project: project,
                showSoftSubtitles: showSoftSubtitles,
                showHardSubtitles: showHardSubtitles,
                editingMode: editingMode,
                isEditingText: isEditingText,
                showSoftSubtitlesTip: $showSoftSubtitlesTip,
                showHardSubtitlesTip: $showHardSubtitlesTip,
                showSelectionTip: $showSelectionTip,
                showCreationTip: $showCreationTip,
                showSplitTip: $showSplitTip,
                showMergeTip: $showMergeTip,
                softSubtitlesHoverTask: $softSubtitlesHoverTask,
                hardSubtitlesHoverTask: $hardSubtitlesHoverTask,
                selectionHoverTask: $selectionHoverTask,
                creationHoverTask: $creationHoverTask,
                splitHoverTask: $splitHoverTask,
                mergeHoverTask: $mergeHoverTask,
                onSplit: { handleSplitAction() },
                onMerge: { handleMergeAction() }
            )
        }
    }
    
}
