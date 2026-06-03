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
        weak var trackingView: NSView?

        private func clamp(_ value: Double) -> Double {
            min(maxPPS, max(minPPS, value))
        }

        private func applyZoomFactor(_ factor: Double) {
            guard factor.isFinite, factor > 0 else { return }
            let oldPPS = pixelsPerSecond
            let newPPS = clamp(oldPPS * factor)
            guard newPPS != oldPPS else { return }
            onPixelsPerSecondChange?(newPPS)
            onCommit?()
        }

        private func isEventInsideTrackingView(_ event: NSEvent) -> Bool {
            guard let trackingView, let window = trackingView.window, event.window === window else {
                return false
            }
            let point = trackingView.convert(event.locationInWindow, from: nil)
            return trackingView.bounds.contains(point)
        }

        func registerMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self else { return event }

                switch event.type {
                case .scrollWheel:
                    guard event.modifierFlags.contains(.option) else { return event }
                    guard self.isEventInsideTrackingView(event) else { return event }
                    let delta = event.scrollingDeltaY
                    guard delta != 0 else { return event }

                    DispatchQueue.main.async {
                        let factor = delta > 0 ? 1.1 : 0.9
                        self.applyZoomFactor(factor)
                    }
                    // Consume the event so the ScrollView doesn't also scroll vertically.
                    return nil

                case .magnify:
                    guard self.isEventInsideTrackingView(event) else { return event }
                    let magnification = Double(event.magnification)
                    guard magnification != 0 else { return nil }

                    DispatchQueue.main.async {
                        self.applyZoomFactor(1.0 + magnification)
                    }
                    return nil

                default:
                    return event
                }
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
        context.coordinator.trackingView = view
        context.coordinator.registerMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        coord.trackingView = nsView
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
#elseif os(iOS)
import UIKit

struct ScrollZoomModifier: UIViewRepresentable {
    @Binding var pixelsPerSecond: Double
    let minPPS: Double
    let maxPPS: Double
    let playheadTime: Double
    @Binding var scrollPageStartTime: Double
    var onCommit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var pixelsPerSecond: Double = 50
        var minPPS: Double = 0.001
        var maxPPS: Double = 1000
        var basePixelsPerSecond: Double = 50
        var onPixelsPerSecondChange: ((Double) -> Void)?
        var onCommit: (() -> Void)?

        private func clamp(_ value: Double) -> Double {
            min(maxPPS, max(minPPS, value))
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                basePixelsPerSecond = pixelsPerSecond

            case .changed:
                let scale = Double(recognizer.scale)
                guard scale.isFinite, scale > 0 else { return }
                let newPPS = clamp(basePixelsPerSecond * scale)
                guard newPPS != pixelsPerSecond else { return }
                onPixelsPerSecondChange?(newPPS)
                onCommit?()

            case .ended, .cancelled, .failed:
                basePixelsPerSecond = pixelsPerSecond
                onCommit?()

            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        let recognizer = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coord = context.coordinator
        coord.pixelsPerSecond = pixelsPerSecond
        coord.minPPS = minPPS
        coord.maxPPS = maxPPS
        coord.onPixelsPerSecondChange = { newPPS in
            pixelsPerSecond = newPPS
        }
        coord.onCommit = onCommit
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
