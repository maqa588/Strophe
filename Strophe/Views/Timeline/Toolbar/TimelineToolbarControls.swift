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
// MARK: - SplitRequest: Identifiable wrapper for .sheet(item:) API
struct SplitRequest: Identifiable {
    let id = UUID()
    let item: SubtitleItem
    let splitTime: TimeInterval
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

    func timelineInfoBadge(
        foreground: Color = Color.stropheBlue,
        background: Color = Color.stropheBlue.opacity(0.15),
        isCompact: Bool = false
    ) -> some View {
        self
            .font(.system(size: isCompact ? 8 : 9, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, isCompact ? 5 : 6)
            .padding(.vertical, 2)
            .background(background)
            .foregroundColor(foreground)
            .cornerRadius(4)
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

// MARK: - BoundarySeekButton for Hold-to-Seek Subtitle Edges
struct BoundarySeekButton: View {
    let icon: String
    let direction: SubtitleProject.SubtitleBoundaryDirection
    let project: SubtitleProject
    
    @State private var timerTask: Task<Void, Never>? = nil
    @State private var isHolding = false
    
    var body: some View {
        Image(systemName: icon)
            .font(.body.weight(.medium))
            .frame(width: 32, height: 28)
            .foregroundColor(.primary)
            .contentShape(Rectangle())
            .help(direction == .left ? String(localized: "字幕块左对齐") : String(localized: "字幕块右对齐"))
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
            project.seekToSubtitleBoundary(direction)

            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            
            #if os(iOS)
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred()
            #endif
            
            while !Task.isCancelled {
                project.seekToSubtitleBoundary(direction)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }
    
    private func stopScanning() {
        timerTask?.cancel()
        timerTask = nil
    }
}
