import SwiftUI

struct HardSubtitleOverlayView: View {
    @ObservedObject var project: SubtitleProject
    @ObservedObject private var store = StyleAndGroupStore.shared

    var body: some View {
        GeometryReader { proxy in
            VStack {
                Spacer()
                let cues = project.resolvedSubtitleCues(at: project.currentTime, store: store)
                if !cues.isEmpty {
                    VStack(spacing: max(6, proxy.size.height * 0.01)) {
                        ForEach(cues) { cue in
                            subtitleView(for: cue, in: proxy.size)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, max(18, proxy.size.width * 0.06))
                    .padding(.bottom, max(28, proxy.size.height * 0.075))
                    .animation(.easeInOut(duration: 0.08), value: cues)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    private func subtitleView(for cue: ResolvedSubtitleCue, in size: CGSize) -> some View {
        let style = cue.style
        let scale = max(0.42, min(size.height / 1080.0, 1.6))
        let fontSize = max(14, style.fontSize * scale)
        let foreground = style.textColor.color
        let outline = style.outlineColor.color
        let shadow = style.shadowColor.color
        let background = style.backgroundColor?.color

        return ZStack {
            if style.outlineWidth > 0 {
                outlinedText(cue.text, style: style, fontSize: fontSize, color: outline, radius: max(1.5, style.outlineWidth * scale))
            }

            Text(cue.text)
                .font(subtitleFont(for: style, size: fontSize))
                .fontWeight(style.isBold ? .bold : .semibold)
                .italic(style.isItalic)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: shadow, radius: max(1, style.shadowRadius * scale), x: 0, y: max(1, 2 * scale))
        }
        .padding(.horizontal, background == nil ? 0 : max(14, 22 * scale))
        .padding(.vertical, background == nil ? 0 : max(6, 10 * scale))
        .background {
            if let background {
                RoundedRectangle(cornerRadius: max(5, 8 * scale), style: .continuous)
                    .fill(background)
            }
        }
        .glow(color: style.isGlowing ? foreground.opacity(0.48) : .clear, radius: style.isGlowing ? max(4, 10 * scale) : 0)
    }

    private func outlinedText(_ text: String, style: ResolvedSubtitleStyle, fontSize: CGFloat, color: Color, radius: CGFloat) -> some View {
        ZStack {
            Text(text).offset(x: -radius, y: 0)
            Text(text).offset(x: radius, y: 0)
            Text(text).offset(x: 0, y: -radius)
            Text(text).offset(x: 0, y: radius)
            Text(text).offset(x: -radius * 0.7, y: -radius * 0.7)
            Text(text).offset(x: radius * 0.7, y: -radius * 0.7)
            Text(text).offset(x: -radius * 0.7, y: radius * 0.7)
            Text(text).offset(x: radius * 0.7, y: radius * 0.7)
        }
        .font(subtitleFont(for: style, size: fontSize))
        .fontWeight(style.isBold ? .bold : .semibold)
        .italic(style.isItalic)
        .foregroundStyle(color)
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func subtitleFont(for style: ResolvedSubtitleStyle, size: CGFloat) -> Font {
        if let fontName = style.fontName, !fontName.isEmpty {
            return .custom(fontName, size: size)
        }
        return .system(size: size, weight: style.isBold ? .bold : .semibold, design: .rounded)
    }
}
