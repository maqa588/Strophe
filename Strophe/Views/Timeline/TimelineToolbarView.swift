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
struct TimelineToolbarView: View {
    let project: SubtitleProject
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    // Dynamic available width state to achieve fluid cross-platform responsiveness
    @State private var availableWidth: CGFloat = 800
    
    private var isCompact: Bool {
        return availableWidth < 540
    }
    
    // Local state variables for layout and rendering, keeping body evaluations isolated
    @State private var targetSpeed: Double = 1.0
    @State private var showSoftSubtitles: Bool = false
    @State private var editingMode: TimelineEditingMode = .selection
    @State private var videoURL: URL? = nil
    @State private var isAudioOnly: Bool = false
    @State private var videoFrameRate: Double = 30.0
    @State private var waveformData: WaveformData? = nil
    @State private var playbackRate: Double = 0.0
    @State private var isEditingText: Bool = false
    
    @State private var showSoftSubtitlesTip = false
    @State private var showSelectionTip = false
    @State private var showCreationTip = false
    
    // 用于 macOS 鼠标延时悬浮（0.5秒）的取消型 Task 实例
    @State private var softSubtitlesHoverTask: Task<Void, Never>? = nil
    @State private var selectionHoverTask: Task<Void, Never>? = nil
    @State private var creationHoverTask: Task<Void, Never>? = nil
    
    var body: some View {
        VStack(spacing: isCompact ? 8 : 0) {
            if isCompact {
                // Compact two-row layout for iPhone & narrow Mac windows
                if videoURL != nil {
                    HStack {
                        #if !os(watchOS)
                        AirPlayRoutePicker()
                            .frame(width: 24, height: 24)
                        #endif
                        
                        Spacer()
                        
                        playbackControls
                        
                        Spacer()
                        
                        // Balance empty spacer to center the playback controls perfectly
                        Spacer()
                            .frame(width: 24)
                    }
                    .padding(.bottom, 2)
                }
                
                HStack {
                    mediaInfoSection
                    Spacer()
                    editingModeControls
                }
            } else {
                // Regular one-row layout for Mac and iPad
                HStack {
                    HStack(spacing: 8) {
                        #if !os(watchOS)
                        if videoURL != nil {
                            AirPlayRoutePicker()
                                .frame(width: 24, height: 24)
                        }
                        #endif
                        mediaInfoSection
                    }
                    
                    Spacer()
                    
                    if videoURL != nil {
                        playbackControls
                    }
                    
                    Spacer()
                    
                    editingModeControls
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        availableWidth = geo.size.width
                    }
                    .onChange(of: geo.size.width) { oldWidth, newWidth in
                        availableWidth = newWidth
                    }
            }
        )
        .onAppear {
            syncStateFromProject()
        }
        .onReceive(project.objectWillChange) { _ in
            // Dispatch to next runloop to read post-change published values
            DispatchQueue.main.async {
                syncStateFromProject()
            }
        }
    }
    
    private func syncStateFromProject() {
        if targetSpeed != project.targetSpeed {
            targetSpeed = project.targetSpeed
        }
        if showSoftSubtitles != project.showSoftSubtitles {
            showSoftSubtitles = project.showSoftSubtitles
        }
        if editingMode != project.editingMode {
            editingMode = project.editingMode
        }
        if videoURL != project.videoURL {
            videoURL = project.videoURL
        }
        if isAudioOnly != project.isAudioOnly {
            isAudioOnly = project.isAudioOnly
        }
        if videoFrameRate != project.videoFrameRate {
            videoFrameRate = project.videoFrameRate
        }
        if waveformData !== project.waveformData {
            waveformData = project.waveformData
        }
        if playbackRate != project.playbackRate {
            playbackRate = project.playbackRate
        }
        if isEditingText != project.isEditingText {
            isEditingText = project.isEditingText
        }
    }
    
    // MARK: - Extracted Components
    
    @ViewBuilder
    private var mediaInfoSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            
            if videoURL != nil {
                if isAudioOnly {
                    let sampleRate = waveformData?.sampleRate ?? 44100.0
                    let khz = sampleRate / 1000.0
                    let isWhole = abs(khz - khz.rounded()) < 0.001
                    let rateString = isWhole ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
                    
                    Text(rateString)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .cornerRadius(4)
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
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .cornerRadius(4)
                }
            }
        }
    }
    
    @ViewBuilder
    private var playbackControls: some View {
        if #available(macOS 26.0, iOS 26.0, *) {
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
                    .help(String(localized: "撤销"))

                    ScanButton(icon: "gobackward.5", isForward: false, project: project)
                        .glassEffect(.regular.interactive())
                    
                    Button(action: { project.togglePlayback() }) {
                        Image(systemName: playbackRate > 0 ? "pause.fill" : "play.fill")
                            .font(.body.weight(.bold))
                            .foregroundStyle(Color.stropheAccent)
                            .frame(width: 36, height: 28)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive())

                    ScanButton(icon: "goforward.5", isForward: true, project: project)
                        .glassEffect(.regular.interactive())

                    Button(action: { project.redo() }) {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.stropheAccent)
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive())
                    .help(String(localized: "重做"))

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
    private var editingModeControls: some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 0) {
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
                            .foregroundStyle(editingMode == .selection ? Color.stropheAccent : .primary)
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcutIf(!isEditingText, "v", modifiers: [])
                    .glassEffect(.regular.interactive())
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
                            .foregroundStyle(editingMode == .creation ? Color.stropheAccent : .primary)
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcutIf(!isEditingText, "d", modifiers: [])
                    .glassEffect(.regular.interactive())
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
            }
        } else {
            EditingModeControlsLegacy(
                project: project,
                showSoftSubtitles: showSoftSubtitles,
                editingMode: editingMode,
                isEditingText: isEditingText,
                showSoftSubtitlesTip: $showSoftSubtitlesTip,
                showSelectionTip: $showSelectionTip,
                showCreationTip: $showCreationTip,
                softSubtitlesHoverTask: $softSubtitlesHoverTask,
                selectionHoverTask: $selectionHoverTask,
                creationHoverTask: $creationHoverTask
            )
        }
    }
}

// MARK: - Rich Interactive Tooltip View
struct RichTooltipView: View {
    let icon: String
    let title: String
    let message: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(Color.accentColor)
                .padding(.top, 1)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundColor(.primary)
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 290)
    }
}

// MARK: - View Extension for Conditional Shortcuts
extension View {
    @ViewBuilder
    func keyboardShortcutIf(_ condition: Bool, _ key: KeyEquivalent, modifiers: EventModifiers = []) -> some View {
        if condition {
            self.keyboardShortcut(key, modifiers: modifiers)
        } else {
            self
        }
    }
}

// MARK: - AirPlayRoutePicker ViewRepresentable
#if os(macOS)
import AppKit
import AVKit

struct AirPlayRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        return picker
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#elseif os(iOS)
import UIKit
import AVKit

struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

// MARK: - ScanButton for Hold-to-Scan Fast Forward / Rewind
struct ScanButton: View {
    let icon: String
    let isForward: Bool
    let project: SubtitleProject
    
    @State private var timerTask: Task<Void, Never>? = nil
    @State private var isHolding = false
    
    var body: some View {
        Image(systemName: icon)
            .font(.body.weight(.medium))
            .frame(width: 32, height: 28)
            .foregroundColor(.primary)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHolding else { return }
                        isHolding = true
                        startScanning()
                    }
                    .onEnded { _ in
                        isHolding = false
                        stopScanning()
                    }
            )
    }
    
    private func startScanning() {
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            // 1. Initial wait of 350ms to distinguish tap from hold
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else {
                // Triggered single tap!
                project.seekDelta(isForward ? 5.0 : -5.0)
                return
            }
            
            // 2. We entered continuous scan mode!
            #if os(iOS)
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred()
            #endif
            
            while !Task.isCancelled {
                // Skip by 1.0s every 100ms
                project.seekDelta(isForward ? 1.0 : -1.0)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    
    private func stopScanning() {
        timerTask?.cancel()
        timerTask = nil
    }
}
