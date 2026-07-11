//
//  Reusable track layout and marquee geometry.
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

let subtitleBlocksCoordinateSpaceName = "subtitleBlocksCoordinateSpace"

nonisolated enum SubtitleTimelineTrackMetrics {
    static let viewportHeight: CGFloat = 120
    static let trackPitch: CGFloat = 34
    static let blockHeight: CGFloat = 28
    static let blockInsetY: CGFloat = 3
    static let viewportInsetY: CGFloat = 3
    static let minimumScale: CGFloat = 0.45
    static let maximumScale: CGFloat = 1.35

    static func totalHeight(trackCount _: Int) -> CGFloat {
        viewportHeight
    }

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(maximumScale, max(minimumScale, scale))
    }

    static func maximumOffset(trackCount: Int, scale: CGFloat) -> CGFloat {
        let visibleContentHeight = (viewportHeight - viewportInsetY * 2) / clampedScale(scale)
        return max(0, CGFloat(max(1, trackCount)) * trackPitch - visibleContentHeight)
    }

    static func clampedOffset(_ offset: CGFloat, trackCount: Int, scale: CGFloat) -> CGFloat {
        min(maximumOffset(trackCount: trackCount, scale: scale), max(0, offset))
    }

    static func laneY(trackIndex: Int, scale: CGFloat, offset: CGFloat) -> CGFloat {
        viewportInsetY + (CGFloat(max(0, trackIndex)) * trackPitch - offset) * clampedScale(scale)
    }

    static func blockY(trackIndex: Int, scale: CGFloat, offset: CGFloat) -> CGFloat {
        laneY(trackIndex: trackIndex, scale: scale, offset: offset) + blockInsetY * clampedScale(scale)
    }

    static func scaledTrackPitch(_ scale: CGFloat) -> CGFloat {
        trackPitch * clampedScale(scale)
    }

    static func scaledBlockHeight(_ scale: CGFloat) -> CGFloat {
        blockHeight * clampedScale(scale)
    }

    static func trackIndex(at y: CGFloat, scale: CGFloat, offset: CGFloat) -> Int {
        Int(floor(((y - viewportInsetY) / clampedScale(scale) + offset) / trackPitch))
    }
}

nonisolated enum SubtitleMarqueeSelectionGeometry {
    static func normalizedRect(from start: CGPoint, to current: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: max(1, abs(current.x - start.x)),
            height: max(1, abs(current.y - start.y))
        )
    }
}

private nonisolated struct SubtitleBlockHitShape: Shape {
    let rects: [CGRect]

    func path(in _: CGRect) -> Path {
        var path = Path()
        for rect in rects {
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: 4, height: 4))
        }
        return path
    }
}
