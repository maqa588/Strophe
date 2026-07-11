//
//  TimelineToolbarViewLegacy.swift
//  Strophe
//
//  Legacy toolbar components for macOS < 26 / iOS < 26
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct PlaybackControlsLegacy: View {
    let project: SubtitleProject
    let targetSpeed: Double
    let playbackRate: Double
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: { project.undo() }) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.body.weight(.medium))
                    .frame(width: 32, height: 28)
                    .foregroundColor(.primary)
                    .cornerRadius(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "undo"))

            BoundarySeekButton(icon: "gobackward", direction: .left, project: project)

            Button(action: { project.togglePlayback() }) {
                Image(systemName: playbackRate > 0 ? "pause.fill" : "play.fill")
                    .font(.body.weight(.bold))
                    .frame(width: 36, height: 28)
                    .foregroundColor(.white)
                    .background(Color.stropheAccent)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)

            BoundarySeekButton(icon: "goforward", direction: .right, project: project)

            Button(action: { project.redo() }) {
                Image(systemName: "arrow.uturn.forward")
                    .font(.body.weight(.medium))
                    .frame(width: 32, height: 28)
                    .foregroundColor(.primary)
                    .cornerRadius(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                    .background(Color.primary.opacity(0.05))
                    .foregroundColor(.primary)
                    .cornerRadius(6)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 44)
        }
        .padding(2)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }
}

struct EditingModeControlsLegacy: View {
    let project: SubtitleProject
    let showSoftSubtitles: Bool
    let showHardSubtitles: Bool
    let editingMode: TimelineEditingMode
    let isEditingText: Bool
    
    @Binding var showSoftSubtitlesTip: Bool
    @Binding var showHardSubtitlesTip: Bool
    @Binding var showSelectionTip: Bool
    @Binding var showCreationTip: Bool
    @Binding var showSplitTip: Bool
    @Binding var showMergeTip: Bool
    
    @Binding var softSubtitlesHoverTask: Task<Void, Never>?
    @Binding var hardSubtitlesHoverTask: Task<Void, Never>?
    @Binding var selectionHoverTask: Task<Void, Never>?
    @Binding var creationHoverTask: Task<Void, Never>?
    @Binding var splitHoverTask: Task<Void, Never>?
    @Binding var mergeHoverTask: Task<Void, Never>?
    
    var onSplit: () -> Void
    var onMerge: () -> Void
    
    private func legacyButton<Content: View>(
        action: @escaping () -> Void,
        isActive: Bool,
        icon: String,
        tipBinding: Binding<Bool>,
        hoverTask: Binding<Task<Void, Never>?>,
        tooltipIcon: String,
        tooltipTitle: String,
        tooltipMessage: String,
        shortcut: KeyEquivalent?,
        modifiers: EventModifiers = [],
        @ViewBuilder label: () -> Content
    ) -> some View {
        Button(action: action) {
            label()
                .frame(width: 32, height: 28)
                .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
                .foregroundColor(isActive ? .accentColor : .primary)
                .cornerRadius(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .optionalKeyboardShortcut(shortcut, enabled: !isEditingText, modifiers: modifiers)
        #if os(iOS)
        .popover(isPresented: tipBinding, arrowEdge: .top) {
            RichTooltipView(icon: tooltipIcon, title: tooltipTitle, message: tooltipMessage)
        }
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.3).onEnded { _ in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            tipBinding.wrappedValue = true
        })
        .onHover { hovering in
            hoverTask.wrappedValue?.cancel()
            if hovering {
                hoverTask.wrappedValue = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if !Task.isCancelled { tipBinding.wrappedValue = true }
                }
            } else { tipBinding.wrappedValue = false }
        }
        #else
        .help("\(tooltipTitle)\n\(tooltipMessage)")
        #endif
    }
    
    /// 无快捷键版本的 legacyButton（用于切分/合并等操作按钮）
    private func legacyActionButton<Content: View>(
        action: @escaping () -> Void,
        icon: String,
        tipBinding: Binding<Bool>,
        hoverTask: Binding<Task<Void, Never>?>,
        tooltipIcon: String,
        tooltipTitle: String,
        tooltipMessage: String,
        @ViewBuilder label: () -> Content
    ) -> some View {
        Button(action: action) {
            label()
                .frame(width: 32, height: 28)
                .background(Color.clear)
                .foregroundColor(.primary)
                .cornerRadius(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .popover(isPresented: tipBinding, arrowEdge: .top) {
            RichTooltipView(icon: tooltipIcon, title: tooltipTitle, message: tooltipMessage)
        }
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.3).onEnded { _ in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            tipBinding.wrappedValue = true
        })
        .onHover { hovering in
            hoverTask.wrappedValue?.cancel()
            if hovering {
                hoverTask.wrappedValue = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if !Task.isCancelled { tipBinding.wrappedValue = true }
                }
            } else { tipBinding.wrappedValue = false }
        }
        #else
        .help("\(tooltipTitle)\n\(tooltipMessage)")
        #endif
    }
    
    var body: some View {
        HStack(spacing: 4) {
            // ── 切分按钮 ──
            legacyActionButton(
                action: onSplit,
                icon: "scissors",
                tipBinding: $showSplitTip,
                hoverTask: $splitHoverTask,
                tooltipIcon: "scissors",
                tooltipTitle: String(localized: "split_subtitles"),
                tooltipMessage: String(localized: "use_the_playhead_as_the")
            ) {
                Image(systemName: "scissors")
                    .font(.body.weight(.medium))
            }
            
            // ── 合并按钮 ──
            legacyActionButton(
                action: onMerge,
                icon: "arrow.down.right.and.arrow.up.left",
                tipBinding: $showMergeTip,
                hoverTask: $mergeHoverTask,
                tooltipIcon: "arrow.down.right.and.arrow.up.left",
                tooltipTitle: String(localized: "merge_subtitles"),
                tooltipMessage: String(localized: "merge_the_selected_consecutive_subtitle")
            ) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.body.weight(.medium))
            }

            // ── 软字幕预览按钮 ──
            legacyButton(
                action: { project.showSoftSubtitles.toggle() },
                isActive: showSoftSubtitles,
                icon: showSoftSubtitles ? "captions.bubble.fill" : "captions.bubble",
                tipBinding: $showSoftSubtitlesTip,
                hoverTask: $softSubtitlesHoverTask,
                tooltipIcon: "captions.bubble",
                tooltipTitle: String(localized: "soft_subtitle_preview"),
                tooltipMessage: String(localized: "click_to_toggle_real_time"),
                shortcut: "s",
                modifiers: [.option]
            ) {
                Image(systemName: showSoftSubtitles ? "captions.bubble.fill" : "captions.bubble")
                    .font(.body.weight(.medium))
            }

            // ── 硬字幕预览按钮 ──
            legacyButton(
                action: { project.showHardSubtitles.toggle() },
                isActive: showHardSubtitles,
                icon: "list.and.film",
                tipBinding: $showHardSubtitlesTip,
                hoverTask: $hardSubtitlesHoverTask,
                tooltipIcon: "list.and.film",
                tooltipTitle: String(localized: "hard_subtitle_preview"),
                tooltipMessage: String(localized: "click_to_turn_onoff_the"),
                shortcut: nil
            ) {
                Image(systemName: "list.and.film")
                    .font(.body.weight(.medium))
            }

            legacyButton(
                action: { project.editingMode = .selection },
                isActive: editingMode == .selection,
                icon: "cursorarrow",
                tipBinding: $showSelectionTip,
                hoverTask: $selectionHoverTask,
                tooltipIcon: "cursorarrow",
                tooltipTitle: String(localized: "selection_tool"),
                tooltipMessage: String(localized: "edit_script_text_drag_timeline"),
                shortcut: "v"
            ) {
                Image(systemName: "cursorarrow")
                    .font(.body.weight(.medium))
            }

            legacyButton(
                action: { project.editingMode = .creation },
                isActive: editingMode == .creation,
                icon: "hand.draw",
                tipBinding: $showCreationTip,
                hoverTask: $creationHoverTask,
                tooltipIcon: "hand.draw",
                tooltipTitle: String(localized: "quick_creation_slap_tool"),
                tooltipMessage: String(localized: "drag_timeline_to_create_subtitle"),
                shortcut: "d"
            ) {
                Image(systemName: "hand.draw")
                    .font(.body.weight(.medium))
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
    }
}

private extension View {
    @ViewBuilder
    func optionalKeyboardShortcut(_ key: KeyEquivalent?, enabled: Bool, modifiers: EventModifiers = []) -> some View {
        if enabled, let key {
            self.keyboardShortcut(key, modifiers: modifiers)
        } else {
            self
        }
    }
}
