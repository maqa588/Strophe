//
//  ScrollViewTracker.swift
//  Strophe
//
//  Created by Antigravity on 2026/06/03.
//

import SwiftUI

#if os(macOS)
import AppKit

struct ScrollViewTracker: NSViewRepresentable {
    let scrollPageStartTime: Double
    let pixelsPerSecond: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var lastScrollPageStartTime: Double = -1
        var lastPixelsPerSecond: Double = -1
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        // Only scroll when the target position actually changed
        guard scrollPageStartTime != coord.lastScrollPageStartTime ||
              pixelsPerSecond != coord.lastPixelsPerSecond else { return }
        coord.lastScrollPageStartTime = scrollPageStartTime
        coord.lastPixelsPerSecond = pixelsPerSecond

        guard let scrollView = nsView.enclosingScrollView else { return }
        let targetX = CGFloat(scrollPageStartTime * pixelsPerSecond)
        let currentX = scrollView.contentView.bounds.origin.x
        guard abs(currentX - targetX) > 0.5 else { return }
        let newPoint = NSPoint(x: targetX, y: scrollView.contentView.bounds.origin.y)
        scrollView.contentView.scroll(to: newPoint)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
#else
import UIKit

struct ScrollViewTracker: UIViewRepresentable {
    let scrollPageStartTime: Double
    let pixelsPerSecond: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var lastScrollPageStartTime: Double = -1
        var lastPixelsPerSecond: Double = -1
    }

    func makeUIView(context: Context) -> UIView {
        UIView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coord = context.coordinator
        // Only scroll when the target position actually changed
        guard scrollPageStartTime != coord.lastScrollPageStartTime ||
              pixelsPerSecond != coord.lastPixelsPerSecond else { return }
        coord.lastScrollPageStartTime = scrollPageStartTime
        coord.lastPixelsPerSecond = pixelsPerSecond

        var current: UIView? = uiView
        while let view = current {
            if let scrollView = view as? UIScrollView {
                let targetX = CGFloat(scrollPageStartTime * pixelsPerSecond)
                let currentOffset = scrollView.contentOffset.x
                guard abs(currentOffset - targetX) > 0.5 else { break }
                scrollView.setContentOffset(CGPoint(x: targetX, y: scrollView.contentOffset.y), animated: false)
                break
            }
            current = view.superview
        }
    }
}
#endif
