//
//  Theme.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/16.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - VisualEffectView

#if os(macOS)
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .followsWindowActiveState

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}
#else
struct VisualEffectView: UIViewRepresentable {
    var style: UIBlurEffect.Style = .systemMaterial

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}
#endif

// MARK: - View glow helper

extension View {
    func glow(color: Color, radius: CGFloat) -> some View {
        self
            .shadow(color: color, radius: radius)
            .shadow(color: color, radius: radius)
    }
}

// MARK: - Brand Adaptive Colors

extension Color {
    // Helper initializer for cross-platform adaptive colors
    init(light: Color, dark: Color) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil {
                return NSColor(dark)
            } else {
                return NSColor(light)
            }
        })
        #elseif canImport(UIKit)
        self.init(uiColor: UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        self.init(light)
        #endif
    }
}

extension Color {
    // 1. Main background color (milky white in light mode, warm dark in dark mode)
    static let stropheBackground = Color(
        light: Color(red: 0.98, green: 0.96, blue: 0.94), // #FAF6F0
        dark: Color(red: 0.11, green: 0.10, blue: 0.09)   // #1C1A18
    )

    // 2. Secondary panel / card background (warm gray in light mode, slightly lighter warm dark in dark mode)
    static let stropheSecondaryBackground = Color(
        light: Color(red: 0.92, green: 0.91, blue: 0.88), // #ECEAE0
        dark: Color(red: 0.16, green: 0.15, blue: 0.14)   // #2A2723
    )

    // 3. Brand accent color (C0392B red playhead / selection / cursor)
    static let stropheAccent = Color(red: 0.75, green: 0.22, blue: 0.17) // #C0392B

    // 4. Primary text color (default dark in light mode, creamy white in dark mode)
    static let stropheText = Color(
        light: Color.primary,
        dark: Color(red: 0.94, green: 0.93, blue: 0.91)   // #F0EDE8
    )

    // 5. Border / Divider / Frame color (warm gray border / divider)
    static let stropheBorder = Color(
        light: Color(red: 0.85, green: 0.82, blue: 0.77), // #D9D1C5
        dark: Color(red: 0.29, green: 0.27, blue: 0.25)   // #4A4540
    )

    // 6. Waveform Peak (warm charcoal in light, warm copper in dark)
    static let stropheWaveformPeak = Color(
        light: Color(red: 0.5, green: 0.45, blue: 0.4),   // warm brown-charcoal
        dark: Color(red: 0.8, green: 0.6, blue: 0.45)     // warm copper-gold
    )

    // 7. Waveform RMS
    static let stropheWaveformRMS = Color(
        light: Color(red: 0.7, green: 0.65, blue: 0.6).opacity(0.6),
        dark: Color(red: 0.9, green: 0.8, blue: 0.7).opacity(0.6)
    )

    // 8. Timeline top divider (soft dark overlay line, avoids harsh high-contrast white illusion)
    static let stropheTimelineDivider = Color(
        light: Color.black.opacity(0.12),
        dark: Color.white.opacity(0.12)
    )
}
