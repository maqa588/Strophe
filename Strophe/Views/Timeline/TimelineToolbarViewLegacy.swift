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
            ScanButton(icon: "gobackward.5", isForward: false, project: project)

            Button(action: { project.togglePlayback() }) {
                Image(systemName: playbackRate > 0 ? "pause.fill" : "play.fill")
                    .font(.body.weight(.bold))
                    .frame(width: 36, height: 28)
                    .foregroundColor(.white)
                    .background(Color.stropheAccent)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)

            ScanButton(icon: "goforward.5", isForward: true, project: project)

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
    let editingMode: TimelineEditingMode
    let isEditingText: Bool
    
    @Binding var showSoftSubtitlesTip: Bool
    @Binding var showSelectionTip: Bool
    @Binding var showCreationTip: Bool
    
    @Binding var softSubtitlesHoverTask: Task<Void, Never>?
    @Binding var selectionHoverTask: Task<Void, Never>?
    @Binding var creationHoverTask: Task<Void, Never>?
    
    var body: some View {
        HStack(spacing: 4) {
            Button(action: { project.showSoftSubtitles.toggle() }) {
                Image(systemName: showSoftSubtitles ? "captions.bubble.fill" : "captions.bubble")
                    .font(.body.weight(.medium))
                    .frame(width: 32, height: 28)
                    .background(showSoftSubtitles ? Color.accentColor.opacity(0.2) : Color.clear)
                    .foregroundColor(showSoftSubtitles ? .accentColor : .primary)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .keyboardShortcutIf(!isEditingText, "s", modifiers: [.option])
            .popover(isPresented: $showSoftSubtitlesTip, arrowEdge: .top) {
                RichTooltipView(icon: "captions.bubble", title: String(localized: "软字幕预览"), message: String(localized: "软字幕预览提示信息"))
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

            Button(action: { project.editingMode = .selection }) {
                Image(systemName: "cursorarrow")
                    .font(.body.weight(.medium))
                    .frame(width: 32, height: 28)
                    .background(editingMode == .selection ? Color.accentColor.opacity(0.2) : Color.clear)
                    .foregroundColor(editingMode == .selection ? .accentColor : .primary)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .keyboardShortcutIf(!isEditingText, "v", modifiers: [])
            .popover(isPresented: $showSelectionTip, arrowEdge: .top) {
                RichTooltipView(icon: "cursorarrow", title: String(localized: "选择工具"), message: String(localized: "选择工具提示信息"))
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
                    .frame(width: 32, height: 28)
                    .background(editingMode == .creation ? Color.accentColor.opacity(0.2) : Color.clear)
                    .foregroundColor(editingMode == .creation ? .accentColor : .primary)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .keyboardShortcutIf(!isEditingText, "d", modifiers: [])
            .popover(isPresented: $showCreationTip, arrowEdge: .top) {
                RichTooltipView(icon: "hand.draw", title: String(localized: "快速创建与拍打工具"), message: String(localized: "快速创建与拍打工具提示信息"))
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
        .padding(2)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
    }
}
