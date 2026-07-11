//
//  SubtitleSplitView.swift
//  Strophe
//
//  Interactive text splitting view for subtitle block splitting
//

import SwiftUI

#if os(macOS)
import AppKit
#endif

/// 字幕切分交互视图：显示分词游标，让用户选择文本切分点
struct SubtitleSplitView: View {
    let item: SubtitleItem
    let splitTime: TimeInterval
    let project: SubtitleProject
    let onDismiss: () -> Void

    /// 游标在文本中的位置（0 = 最左，text.count = 最右）
    @State private var cursorPosition: Int

    private var characters: [Character] {
        Array(item.text)
    }

    private var leftText: String {
        String(characters.prefix(cursorPosition)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var rightText: String {
        String(characters.suffix(characters.count - cursorPosition)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(item: SubtitleItem, splitTime: TimeInterval, project: SubtitleProject, onDismiss: @escaping () -> Void) {
        self.item = item
        self.splitTime = splitTime
        self.project = project
        self.onDismiss = onDismiss

        // 初始游标位置：按时间比例估算
        let startTime = item.startTime ?? 0
        let endTime = item.endTime ?? 1
        let duration = max(0.001, endTime - startTime)
        let ratio = (splitTime - startTime) / duration
        let estimatedPosition = Int(round(ratio * Double(item.text.count)))
        let clampedPosition = max(1, min(item.text.count - 1, estimatedPosition))
        self._cursorPosition = State(initialValue: clampedPosition)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        let ms = Int((t - Double(Int(t))) * 1000)
        return String(format: "%02d:%02d.%03d", m, s, ms)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ───────────────────────────────────────────
            HStack {
                Image(systemName: "scissors")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.stropheAccent)
                Text(String(localized: "split_subtitles"))
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // ── Main scrollable area ──────────────────────────────
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    Text(String(localized: "click_character_spacing_to_move"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // 文本分词显示
                    splitTextView
                        .padding(.horizontal, 8)

                    // 左右箭头微调
                    HStack(spacing: 20) {
                        Button(action: {
                            if cursorPosition > 1 { cursorPosition -= 1 }
                        }) {
                            Image(systemName: "chevron.left.circle.fill")
                                .font(.title2)
                                .foregroundStyle(cursorPosition > 1 ? Color.stropheAccent : Color.secondary.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                        .disabled(cursorPosition <= 1)

                        Text(String(localized: "游标位置：\(cursorPosition) / \(characters.count)"))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Button(action: {
                            if cursorPosition < characters.count - 1 { cursorPosition += 1 }
                        }) {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.title2)
                                .foregroundStyle(cursorPosition < characters.count - 1 ? Color.stropheAccent : Color.secondary.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                        .disabled(cursorPosition >= characters.count - 1)
                    }

                    Divider()

                    // ── 时间范围预览 ──────────────────────────────
                    HStack(alignment: .top, spacing: 0) {
                        // 左半
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.stropheBlue)
                                    .frame(width: 8, height: 8)
                                Text(String(localized: "left_half"))
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                            }
                            Text(formatTime(item.startTime ?? 0) + " → " + formatTime(splitTime))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                                .minimumScaleFactor(0.75)
                                .lineLimit(1)
                            Text("「\(leftText)」")
                                .font(.caption)
                                .foregroundStyle(Color.stropheBlue)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)

                        Rectangle()
                            .fill(Color.secondary.opacity(0.3))
                            .frame(width: 1, height: 56)
                            .padding(.top, 4)

                        // 右半
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 8, height: 8)
                                Text(String(localized: "right_half"))
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                            }
                            Text(formatTime(splitTime) + " → " + formatTime(item.endTime ?? 0))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                                .minimumScaleFactor(0.75)
                                .lineLimit(1)
                            Text("「\(rightText)」")
                                .font(.caption)
                                .foregroundStyle(Color.orange)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 4)
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
            }

            Divider()

            // ── 操作按钮 ─────────────────────────────────────────
            HStack(spacing: 12) {
                Button(action: onDismiss) {
                    Text(String(localized: "cancel"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                #if os(macOS)
                .keyboardShortcut(.escape, modifiers: [])
                #endif

                Button(action: {
                    project.splitSubtitle(
                        id: item.id,
                        at: splitTime,
                        leftText: leftText,
                        rightText: rightText
                    )
                    onDismiss()
                }) {
                    Text(String(localized: "confirm_split"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stropheAccent)
                .disabled(leftText.isEmpty || rightText.isEmpty)
                #if os(macOS)
                .keyboardShortcut(.return, modifiers: [])
                #endif
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        // ── 平台适配尺寸与背景 ────────────────────────────────────
        #if os(macOS)
        .frame(width: 440, height: 400)
        .background(VisualEffectView(material: .sheet, blendingMode: .behindWindow))
        .cornerRadius(16)
        .background(
            SubtitleSplitKeyMonitor(
                moveLeft: {
                    if cursorPosition > 1 { cursorPosition -= 1 }
                },
                moveRight: {
                    if cursorPosition < characters.count - 1 { cursorPosition += 1 }
                }
            )
        )
        #else
        // iOS/iPadOS: 全宽自适应，背景由系统 sheet 提供，无需手动设
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .cornerRadius(16)
        #endif
    }

    // MARK: - 分词文本视图

    /// 每个字符独立渲染，字符间隔可点击定位游标
    @ViewBuilder
    private var splitTextView: some View {
        let charArray = characters

        WrappingHStack(alignment: .center, spacing: 0) {
            ForEach(Array(charArray.enumerated()), id: \.offset) { index, char in
                // 字符间游标点击区（在字符之前）
                if index > 0 {
                    Rectangle()
                        .fill(index == cursorPosition ? Color.stropheAccent : Color.clear)
                        .frame(width: index == cursorPosition ? 2.5 : 8, height: 32)
                        .animation(.easeInOut(duration: 0.15), value: cursorPosition)
                        .contentShape(Rectangle().inset(by: -4))
                        .onTapGesture {
                            cursorPosition = index
                        }
                }

                // 字符显示
                Text(String(char))
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(index < cursorPosition ? Color.stropheBlue : Color.orange)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if index < cursorPosition {
                            cursorPosition = index + 1
                        } else {
                            cursorPosition = index
                        }
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

#if os(macOS)
private struct SubtitleSplitKeyMonitor: NSViewRepresentable {
    let moveLeft: () -> Void
    let moveRight: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(moveLeft: moveLeft, moveRight: moveRight)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.trackingView = view
        context.coordinator.registerMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.trackingView = nsView
        context.coordinator.moveLeft = moveLeft
        context.coordinator.moveRight = moveRight
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.unregisterMonitor()
    }

    final class Coordinator {
        weak var trackingView: NSView?
        var moveLeft: () -> Void
        var moveRight: () -> Void
        private var monitor: Any?

        init(moveLeft: @escaping () -> Void, moveRight: @escaping () -> Void) {
            self.moveLeft = moveLeft
            self.moveRight = moveRight
        }

        func registerMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let window = trackingView?.window,
                      event.window === window,
                      !Self.isEditingText(in: window)
                else {
                    return event
                }

                switch event.keyCode {
                case 123:
                    moveLeft()
                    return nil
                case 124:
                    moveRight()
                    return nil
                default:
                    return event
                }
            }
        }

        func unregisterMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private static func isEditingText(in window: NSWindow) -> Bool {
            guard let responder = window.firstResponder else { return false }
            return responder is NSTextView || responder is NSTextField
        }
    }
}
#endif

// MARK: - WrappingHStack

/// 自适应换行的水平布局，用于字符级别的分词展示
struct WrappingHStack: Layout {
    var alignment: VerticalAlignment
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        computeLayout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    struct LayoutResult {
        var size: CGSize
        var positions: [CGPoint]
    }

    func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, currentX - spacing)
        }

        return LayoutResult(
            size: CGSize(width: totalWidth, height: currentY + lineHeight),
            positions: positions
        )
    }
}
