import AVFoundation
import SwiftUI

#if os(macOS)
    import AppKit
#endif

enum VideoDisplaySize {
    case audioOnly
    case landscape(ratio: CGFloat)
    case square
    case portrait(clampedToSquare: Bool)
}

@MainActor
final class VideoProperties {

    static let shared = VideoProperties()

    private init() {}

    func detectVideoSize(from url: URL) async -> (naturalSize: CGSize, displayRatio: CGFloat?, isVideo: Bool) {
        let detection = await FormatDetector.shared.detect(url: url)
        if !detection.isAVFoundationCompatible {
            print("🔊 Bypassing AVFoundation video size detection for \(url.lastPathComponent)")
            return (CGSize(width: 1920, height: 1080), 16.0 / 9.0, true)
        }

        let asset = AVURLAsset(url: url)

        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            return (.zero, nil, false)
        }

        let size = try? await videoTrack.load(.naturalSize)
        let transform = try? await videoTrack.load(.preferredTransform)

        guard let naturalSize = size, let txf = transform, naturalSize.width > 0, naturalSize.height > 0 else {
            return (.zero, nil, true)
        }

        let displaySize = naturalSize.applying(txf)

        let w = abs(displaySize.width)
        let h = abs(displaySize.height)

        let ratio: CGFloat = h > 0 ? w / h : 1.0

        return (naturalSize, ratio, true)
    }

    #if os(macOS)
        func adjustWindowForVideoSize(
            _ size: CGSize,
            isAudioOnly: Bool,
            minWindowSize: CGSize = CGSize(width: 640, height: 480),
            heightMarginFactor: CGFloat = 0.88
        ) {
            guard !isAudioOnly, size.width > 0, size.height > 0 else { return }

            let ratio = size.width / size.height
            applyAspectRatio(ratio, minWindowSize: minWindowSize, heightMarginFactor: heightMarginFactor)
        }

        /// Returns a plausible sidebar width without mistaking the detail pane for it.
        private func safeSidebarWidth(in view: NSView) -> CGFloat {
            let fallbackWidth: CGFloat = 260

            guard let splitView = findFirstSplitView(in: view),
                splitView.subviews.count >= 2
            else {
                return fallbackWidth
            }

            let sidebar = splitView.subviews[0]
            let width = sidebar.frame.width
            if splitView.isSubviewCollapsed(sidebar) || width < 10 {
                return 0
            }
            return (50...450).contains(width) ? width : fallbackWidth
        }

        private func findFirstSplitView(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            for subview in view.subviews {
                if let split = findFirstSplitView(in: subview) { return split }
            }
            return nil
        }

        private func applyAspectRatio(
            _ rawRatio: CGFloat,
            minWindowSize: CGSize,
            heightMarginFactor: CGFloat
        ) {
            guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first else { return }
            guard let screen = window.screen ?? NSScreen.main else { return }

            let visibleFrame = screen.visibleFrame
            let effectiveRatio = max(rawRatio, 1.0)

            guard let contentView = window.contentView else { return }

            let sidebarWidth = safeSidebarWidth(in: contentView)

            let topToolbarHeight: CGFloat = 52
            let timelineHeight: CGFloat = 235
            let nonVideoHeight = timelineHeight + topToolbarHeight

            let maxVideoHeight = (visibleFrame.height * heightMarginFactor) - nonVideoHeight

            var videoHeight = maxVideoHeight
            var videoWidth = videoHeight * effectiveRatio

            if (videoWidth + sidebarWidth) > visibleFrame.width {
                videoWidth = visibleFrame.width - sidebarWidth
                videoHeight = videoWidth / effectiveRatio
            }

            videoWidth = max(videoWidth, minWindowSize.width)
            videoHeight = videoWidth / effectiveRatio

            let targetWidth = videoWidth + sidebarWidth
            // `contentRect` excludes the native title bar but includes custom content.
            let targetHeight = videoHeight + timelineHeight

            let contentRect = NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
            var frameRect = window.frameRect(forContentRect: contentRect)

            let centeredX = visibleFrame.midX - frameRect.width / 2.0
            let centeredY = visibleFrame.origin.y + (visibleFrame.height - frameRect.height) / 2.0

            frameRect.origin.x = centeredX
            frameRect.origin.y = centeredY

            window.setFrame(frameRect, display: true, animate: true)
        }
    #endif
}
