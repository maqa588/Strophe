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

/// Lets the user choose a character boundary for splitting a subtitle cue.
struct SubtitleSplitView: View {
    let item: SubtitleItem
    let splitTime: TimeInterval
    let project: SubtitleProject
    let onDismiss: () -> Void

    /// Boundary index in `characters`, from zero through `characters.count`.
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

        // Estimate the initial text boundary from the playhead's cue position.
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
        #if os(macOS)
            macOSContent
        #else
            iOSContent
        #endif
    }

    #if os(macOS)
        private var macOSContent: some View {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("split_subtitles")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.stropheText)

                    Spacer()

                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)

                Divider()
                    .background(Color.stropheBorder)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        cursorSplitCard
                        splitResultPreviewCard
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }

                Divider()
                    .background(Color.stropheBorder)

                // Bottom Actions
                HStack {
                    Spacer()

                    Button(String(localized: "cancel")) {
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.stropheText)

                    Button(String(localized: "confirm_split")) {
                        project.splitSubtitle(
                            id: item.id,
                            at: splitTime,
                            leftText: leftText,
                            rightText: rightText
                        )
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.stropheAccent)
                    .disabled(leftText.isEmpty || rightText.isEmpty)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .frame(width: 500, height: 480)
            .background(VisualEffectView(material: .sheet, blendingMode: .behindWindow))
        }
    #endif

    private var iOSContent: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    cursorSplitCard
                    splitResultPreviewCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle(String(localized: "split_subtitles"))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { onDismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "confirm_split")) {
                        project.splitSubtitle(
                            id: item.id,
                            at: splitTime,
                            leftText: leftText,
                            rightText: rightText
                        )
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.stropheAccent)
                    .disabled(leftText.isEmpty || rightText.isEmpty)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cursorSplitCard: some View {
        VStack(spacing: 14) {
            Text(String(localized: "click_character_spacing_to_move"))
                .font(.caption)
                .foregroundStyle(.secondary)

            splitTextView
                .padding(.horizontal, 8)

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

                Text(String(localized: "playhead_position_format \(cursorPosition) \(characters.count)"))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button(action: {
                    if cursorPosition < characters.count - 1 { cursorPosition += 1 }
                }) {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            cursorPosition < characters.count - 1 ? Color.stropheAccent : Color.secondary.opacity(0.3))
                }
                .buttonStyle(.plain)
                .disabled(cursorPosition >= characters.count - 1)
            }
        }
        .padding(16)
        .background(Color.stropheSecondaryBackground.opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.stropheBorder, lineWidth: 1)
        )
    }

    private var splitResultPreviewCard: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
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
                    Text("bracket_format \(leftText)")
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
                    Text("bracket_format \(rightText)")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(Color.stropheSecondaryBackground.opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.stropheBorder, lineWidth: 1)
        )
    }

    // MARK: - Split text

    /// Renders characters separately so every boundary remains selectable.
    @ViewBuilder
    private var splitTextView: some View {
        let charArray = characters

        WrappingHStack(alignment: .center, spacing: 0) {
            ForEach(Array(charArray.enumerated()), id: \.offset) { index, char in
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

/// A wrapping horizontal layout used for character-level selection.
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
