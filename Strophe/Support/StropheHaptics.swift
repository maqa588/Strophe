//
//  StropheHaptics.swift
//  Strophe
//
//  Centralized haptic feedback. visionOS has no haptics at all — the system
//  substitutes audio cues — so every call site funnels through this type.
//

import Foundation

#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

enum StropheHaptics {
    enum Impact {
        case selection
        case light
        case medium
        case rigid
    }

    static func perform(_ impact: Impact) {
        #if os(macOS)
            switch impact {
            case .selection, .light:
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            case .medium, .rigid:
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        #elseif os(iOS)
            switch impact {
            case .selection:
                UISelectionFeedbackGenerator().selectionChanged()
            case .light:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .medium:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .rigid:
                let generator = UIImpactFeedbackGenerator(style: .rigid)
                generator.prepare()
                generator.impactOccurred(intensity: 1)
            }
        #else
            // visionOS: no haptic hardware. Keep the call sites identical.
            _ = impact
        #endif
    }
}
