//
//  ScrollZoomModifier.swift
//  SwiftSub
//
//  Created by maqa on 2026/5/18.
//

import SwiftUI

#if os(macOS)
struct ScrollZoomModifier: NSViewRepresentable {
    @Binding var pixelsPerSecond: Double
    let minPPS: Double
    let maxPPS: Double
    /// Called each time PPS changes so the parent can debounce the Canvas redraw.
    var onCommit: () -> Void = {}

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            if event.modifierFlags.contains(.option) {
                let delta = event.scrollingDeltaY
                if delta != 0 {
                    DispatchQueue.main.async {
                        let factor = delta > 0 ? 1.1 : 0.9
                        // Direct assignment — no withAnimation → no animation overhead
                        pixelsPerSecond = min(maxPPS, max(minPPS, pixelsPerSecond * factor))
                        onCommit()
                    }
                    return nil
                }
            }
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#else
struct ScrollZoomModifier: View {
    @Binding var pixelsPerSecond: Double
    let minPPS: Double
    let maxPPS: Double
    var onCommit: () -> Void = {}
    var body: some View { EmptyView() }
}
#endif
