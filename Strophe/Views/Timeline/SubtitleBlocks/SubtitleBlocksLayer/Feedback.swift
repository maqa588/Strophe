//
//  Platform feedback and pointer affordances for timeline interaction.
//

import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension SubtitleBlocksLayer {
    func triggerHapticFeedback() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        #elseif os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    func triggerLiftHapticFeedback() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #elseif os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 1)
        #endif
    }

    func updateTimelineCursor(isOverTrimHandle: Bool) {
        #if os(macOS)
        guard isPointingAtTrimHandle != isOverTrimHandle else { return }
        isPointingAtTrimHandle = isOverTrimHandle
        (isOverTrimHandle ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        #endif
    }

    func resetTimelineCursor() {
        #if os(macOS)
        guard isPointingAtTrimHandle else { return }
        isPointingAtTrimHandle = false
        NSCursor.arrow.set()
        #endif
    }
}
