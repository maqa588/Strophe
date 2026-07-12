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
        var lastLeadingInset: CGFloat = -1
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        guard let scrollView = nsView.enclosingScrollView else { return }

        // A horizontal ScrollView that touches a NavigationSplitView edge is
        // automatically extended underneath the sidebar on macOS 26+. AppKit
        // represents the unobscured leading edge with a content inset, so the
        // logical zero position is negative rather than an absolute x = 0.
        // Ignoring that origin puts 00:00 underneath the sidebar.
        let leadingInset = max(
            scrollView.contentInsets.left,
            scrollView.contentView.contentInsets.left
        )

        // Only take control for a programmatic page/zoom change or when the
        // system inset changes. Otherwise an unrelated SwiftUI update would
        // snap a user's manual scroll back to the last requested page.
        guard scrollPageStartTime != coord.lastScrollPageStartTime ||
              pixelsPerSecond != coord.lastPixelsPerSecond ||
              leadingInset != coord.lastLeadingInset else { return }
        coord.lastScrollPageStartTime = scrollPageStartTime
        coord.lastPixelsPerSecond = pixelsPerSecond
        coord.lastLeadingInset = leadingInset

        let targetX = CGFloat(scrollPageStartTime * pixelsPerSecond) - leadingInset
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
        var lastLeadingInset: CGFloat = -1
    }

    func makeUIView(context: Context) -> UIView {
        UIView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coord = context.coordinator
        var current: UIView? = uiView
        while let view = current {
            if let scrollView = view as? UIScrollView {
                // UIScrollView uses a negative content offset for its logical
                // leading edge when a split view contributes a safe-area inset.
                let leadingInset = scrollView.adjustedContentInset.left
                guard scrollPageStartTime != coord.lastScrollPageStartTime ||
                      pixelsPerSecond != coord.lastPixelsPerSecond ||
                      leadingInset != coord.lastLeadingInset else { break }
                coord.lastScrollPageStartTime = scrollPageStartTime
                coord.lastPixelsPerSecond = pixelsPerSecond
                coord.lastLeadingInset = leadingInset

                let targetX = CGFloat(scrollPageStartTime * pixelsPerSecond) - leadingInset
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
