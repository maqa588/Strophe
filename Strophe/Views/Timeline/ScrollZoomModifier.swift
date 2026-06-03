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
    let playheadTime: Double
    @Binding var scrollPageStartTime: Double
    /// Called each time PPS changes so the parent can debounce the Canvas redraw.
    var onCommit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        // Current live values, updated on every updateNSView
        var pixelsPerSecond: Double = 50
        var minPPS: Double = 0.001
        var maxPPS: Double = 1000
        var playheadTime: Double = 0
        var onPixelsPerSecondChange: ((Double) -> Void)?
        var onCommit: (() -> Void)?

        // The single registered monitor — kept for the lifetime of the NSView
        var monitor: Any?

        func registerMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                guard event.modifierFlags.contains(.option) else { return event }
                let delta = event.scrollingDeltaY
                guard delta != 0 else { return event }

                DispatchQueue.main.async {
                    let factor = delta > 0 ? 1.1 : 0.9
                    let oldPPS = self.pixelsPerSecond
                    let newPPS = min(self.maxPPS, max(self.minPPS, oldPPS * factor))
                    guard newPPS != oldPPS else { return }
                    self.onPixelsPerSecondChange?(newPPS)
                    self.onCommit?()
                }
                // Consume the event so the ScrollView doesn't also scroll vertically
                return nil
            }
        }

        func unregisterMonitor() {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.registerMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        coord.pixelsPerSecond = pixelsPerSecond
        coord.minPPS = minPPS
        coord.maxPPS = maxPPS
        coord.playheadTime = playheadTime
        coord.onPixelsPerSecondChange = { newPPS in
            pixelsPerSecond = newPPS
        }
        coord.onCommit = onCommit

        // Ensure the monitor is registered (e.g. after a window change)
        coord.registerMonitor()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.unregisterMonitor()
    }
}
#else
struct ScrollZoomModifier: View {
    @Binding var pixelsPerSecond: Double
    let minPPS: Double
    let maxPPS: Double
    let playheadTime: Double
    @Binding var scrollPageStartTime: Double
    var onCommit: () -> Void = {}
    var body: some View { EmptyView() }
}
#endif
