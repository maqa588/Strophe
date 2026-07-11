//
//  UIKit gesture arbitration for the mobile timeline.
//

import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import GameController
#endif

#if os(iOS)
enum TimelineTouchPanIntent {
    case horizontal
    case vertical
}

/// UIKit owns touch arbitration on iPhone/iPad. The parent scroll view waits for
/// this surface to distinguish block edits, track panning, taps, and long-press
/// marquee selection before beginning its own pan.
struct TimelineTouchInteractionSurface: UIViewRepresentable {
    var containsBlock: (CGPoint) -> Bool
    var canBeginLongPress: (CGPoint) -> Bool
    var shouldBeginPan: (TimelineTouchPanIntent, CGPoint) -> Bool
    var onPanBegan: (TimelineTouchPanIntent, CGPoint) -> Void
    var onPanChanged: (TimelineTouchPanIntent, CGSize) -> Void
    var onPanEnded: (TimelineTouchPanIntent, Bool) -> Void
    var onLongPressBegan: (CGPoint) -> Void
    var onLongPressChanged: (CGSize) -> Void
    var onLongPressEnded: (Bool) -> Void
    var onSingleTap: (CGPoint) -> Void
    var onDoubleTap: (CGPoint) -> Void

    func makeUIView(context _: Context) -> TimelineTouchRoutingView {
        TimelineTouchRoutingView()
    }

    func updateUIView(_ view: TimelineTouchRoutingView, context _: Context) {
        view.containsBlock = containsBlock
        view.canBeginLongPress = canBeginLongPress
        view.shouldBeginPan = shouldBeginPan
        view.onPanBegan = onPanBegan
        view.onPanChanged = onPanChanged
        view.onPanEnded = onPanEnded
        view.onLongPressBegan = onLongPressBegan
        view.onLongPressChanged = onLongPressChanged
        view.onLongPressEnded = onLongPressEnded
        view.onSingleTap = onSingleTap
        view.onDoubleTap = onDoubleTap
    }
}

final class TimelineTouchRoutingView: UIView, UIGestureRecognizerDelegate {
    var containsBlock: (CGPoint) -> Bool = { _ in false }
    var canBeginLongPress: (CGPoint) -> Bool = { _ in false }
    var shouldBeginPan: (TimelineTouchPanIntent, CGPoint) -> Bool = { _, _ in false }
    var onPanBegan: (TimelineTouchPanIntent, CGPoint) -> Void = { _, _ in }
    var onPanChanged: (TimelineTouchPanIntent, CGSize) -> Void = { _, _ in }
    var onPanEnded: (TimelineTouchPanIntent, Bool) -> Void = { _, _ in }
    var onLongPressBegan: (CGPoint) -> Void = { _ in }
    var onLongPressChanged: (CGSize) -> Void = { _ in }
    var onLongPressEnded: (Bool) -> Void = { _ in }
    var onSingleTap: (CGPoint) -> Void = { _ in }
    var onDoubleTap: (CGPoint) -> Void = { _ in }

    private(set) lazy var blockPanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
    private(set) lazy var longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
    private lazy var singleTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
    private lazy var doubleTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
    private var panIntent: TimelineTouchPanIntent = .horizontal
    private var panStartLocation = CGPoint.zero
    private var longPressStart = CGPoint.zero
    private weak var prioritizedScrollView: UIScrollView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        blockPanRecognizer.maximumNumberOfTouches = 1
        blockPanRecognizer.delegate = self
        longPressRecognizer.minimumPressDuration = 0.42
        longPressRecognizer.allowableMovement = 14
        longPressRecognizer.delegate = self
        singleTapRecognizer.numberOfTapsRequired = 1
        singleTapRecognizer.delegate = self
        doubleTapRecognizer.numberOfTapsRequired = 2
        doubleTapRecognizer.delegate = self

        blockPanRecognizer.require(toFail: longPressRecognizer)
        singleTapRecognizer.require(toFail: doubleTapRecognizer)
        addGestureRecognizer(blockPanRecognizer)
        addGestureRecognizer(longPressRecognizer)
        addGestureRecognizer(singleTapRecognizer)
        addGestureRecognizer(doubleTapRecognizer)
    }

    required init?(coder: NSCoder) { nil }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if let touch = touches.first {
            panStartLocation = touch.location(in: self)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        var candidate = superview
        var enclosingScrollView: UIScrollView?
        while let current = candidate {
            if let scrollView = current as? UIScrollView {
                enclosingScrollView = scrollView
                break
            }
            candidate = current.superview
        }
        guard let scrollView = enclosingScrollView,
              prioritizedScrollView !== scrollView else { return }
        prioritizedScrollView = scrollView
        scrollView.panGestureRecognizer.require(toFail: longPressRecognizer)
        scrollView.panGestureRecognizer.require(toFail: blockPanRecognizer)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let location = gestureRecognizer.location(in: self)
        if gestureRecognizer === blockPanRecognizer {
            let velocity = blockPanRecognizer.velocity(in: self)
            panIntent = abs(velocity.x) >= abs(velocity.y) ? .horizontal : .vertical
            return shouldBeginPan(panIntent, panStartLocation)
        }
        if gestureRecognizer === longPressRecognizer {
            return canBeginLongPress(location)
        }
        if gestureRecognizer === singleTapRecognizer
            || gestureRecognizer === doubleTapRecognizer {
            return containsBlock(location)
        }
        return true
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            onPanBegan(panIntent, panStartLocation)
        case .changed:
            let translation = recognizer.translation(in: self)
            onPanChanged(panIntent, CGSize(width: translation.x, height: translation.y))
        case .ended:
            onPanEnded(panIntent, true)
        case .cancelled, .failed:
            onPanEnded(panIntent, false)
        default:
            break
        }
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            longPressStart = recognizer.location(in: self)
            onLongPressBegan(longPressStart)
        case .changed:
            let location = recognizer.location(in: self)
            onLongPressChanged(CGSize(
                width: location.x - longPressStart.x,
                height: location.y - longPressStart.y
            ))
        case .ended:
            onLongPressEnded(true)
        case .cancelled, .failed:
            onLongPressEnded(false)
        default:
            break
        }
    }

    @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
        onSingleTap(recognizer.location(in: self))
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        onDoubleTap(recognizer.location(in: self))
    }
}
#endif
