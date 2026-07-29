import SwiftUI

struct HardSubtitleOverlayView: View {
    @ObservedObject var project: SubtitleProject
    @ObservedObject private var store = StyleAndGroupStore.shared

    var body: some View {
        GeometryReader { proxy in
            let videoSize = project.videoSize.width > 0 && project.videoSize.height > 0
                ? project.videoSize
                : CGSize(width: 1920, height: 1080)
            let displayScale = proxy.size.height / videoSize.height

            TimelineView(
                .animation(
                    minimumInterval: 1 / 60,
                    paused: false
                )
            ) { _ in
                let time = resolvedCurrentTime
                let scene = project.resolvedSubtitleFrameScene(
                    at: time,
                    canvasSize: videoSize,
                    store: store
                )
                ZStack {
                    ForEach(scene.items) { item in
                        subtitle(
                            for: item,
                            presentationTime: scene.presentationTime,
                            videoSize: videoSize,
                            displayScale: displayScale
                        )
                        .position(
                            x: (item.origin.x + item.size.width / 2) * displayScale,
                            y: (item.origin.y + item.size.height / 2) * displayScale
                        )
                        .opacity(item.cue.opacity(at: scene.presentationTime))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func subtitle(
        for item: SubtitleFrameSceneItem,
        presentationTime: Double,
        videoSize: CGSize,
        displayScale: CGFloat
    ) -> some View {
        if item.cue.karaoke != nil {
            KaraokeSubtitleBitmapView(
                cue: item.cue,
                presentationTime: presentationTime,
                canvasSize: videoSize,
                displayScale: displayScale
            )
        } else {
            HardSubtitleBitmapView(
                text: item.cue.text,
                style: item.cue.style,
                canvasSize: videoSize,
                displayScale: displayScale,
                anchor: item.cue.resolvedAnchor
            )
        }
    }

    private var resolvedCurrentTime: Double {
        let engineTime = project.activeEngine?.currentTime
        if let engineTime, engineTime.isFinite {
            return engineTime
        }
        return project.currentTime.isFinite ? project.currentTime : 0
    }
}
