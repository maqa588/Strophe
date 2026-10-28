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
        StropheHaptics.perform(.light)
    }

    func triggerLiftHapticFeedback() {
        StropheHaptics.perform(.rigid)
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
