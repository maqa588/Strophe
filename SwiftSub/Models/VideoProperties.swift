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
    func adjustWindowForVideo(
        url: URL,
        isAudioOnly: Bool,
        minWindowSize: CGSize = CGSize(width: 640, height: 480),
        heightMarginFactor: CGFloat = 0.88
    ) {
        guard !isAudioOnly else { return }

        Task { @MainActor in
            let (_, ratio, hasVideo) = await detectVideoSize(from: url)
            guard hasVideo, let r = ratio else { return }

            applyAspectRatio(r, minWindowSize: minWindowSize, heightMarginFactor: heightMarginFactor)
        }
    }

    private func applyAspectRatio(
        _ rawRatio: CGFloat,
        minWindowSize: CGSize,
        heightMarginFactor: CGFloat
    ) {
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }

        let visibleFrame = screen.visibleFrame

        let effectiveRatio: CGFloat
        if rawRatio < 1.0 {
            effectiveRatio = 1.0
        } else {
            effectiveRatio = rawRatio
        }

        let maxAvailableHeight = visibleFrame.height * heightMarginFactor
        let targetHeight = max(minWindowSize.height, maxAvailableHeight)
        var targetWidth = targetHeight * effectiveRatio

        if targetWidth > visibleFrame.width {
            targetWidth = visibleFrame.width
        }

        targetWidth = max(targetWidth, minWindowSize.width)

        let finalHeight = targetWidth / effectiveRatio

        let contentRect = NSRect(x: 0, y: 0, width: targetWidth, height: finalHeight)

        var frameRect = window.frameRect(forContentRect: contentRect)

        let centeredX = visibleFrame.midX - frameRect.width / 2.0
        let centeredY = visibleFrame.origin.y + (visibleFrame.height - frameRect.height) / 2.0

        frameRect.origin.x = centeredX
        frameRect.origin.y = centeredY

        window.setFrame(frameRect, display: true, animate: true)
    }
    #endif
}
