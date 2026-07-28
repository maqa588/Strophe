import Combine
import SwiftUI

struct HardSubtitleOverlayView: View {
    @ObservedObject var project: SubtitleProject
    @ObservedObject private var store = StyleAndGroupStore.shared
    @State private var displayedScene = SubtitleFrameScene.empty(
        at: 0,
        canvasSize: CGSize(width: 1920, height: 1080)
    )

    var body: some View {
        GeometryReader { proxy in
            let videoSize = project.videoSize.width > 0 && project.videoSize.height > 0
                ? project.videoSize
                : CGSize(width: 1920, height: 1080)
            let displayScale = proxy.size.height / videoSize.height

            ZStack {
                ForEach(displayedScene.items) { item in
                    HardSubtitleBitmapView(
                        text: item.cue.text,
                        style: item.cue.style,
                        canvasSize: videoSize,
                        displayScale: displayScale,
                        anchor: item.cue.resolvedAnchor
                    )
                        .position(
                            x: (item.origin.x + item.size.width / 2) * displayScale,
                            y: (item.origin.y + item.size.height / 2) * displayScale
                        )
                        .opacity(item.cue.opacity(at: displayedScene.presentationTime))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(
                .linear(duration: 0.05),
                value: displayedScene.presentationTime
            )
        }
        .allowsHitTesting(false)
        .task {
            await refreshLoop()
        }
        .stropheOnChange(of: store.activeGroupID) { _ in
            refreshDisplayedCues(at: resolvedCurrentTime)
        }
        .onReceive(project.objectWillChange) { _ in
            refreshDisplayedCues(at: resolvedCurrentTime)
        }
    }

    private var resolvedCurrentTime: Double {
        let engineTime = project.activeEngine?.currentTime
        if let engineTime, engineTime.isFinite {
            return engineTime
        }
        return project.currentTime.isFinite ? project.currentTime : 0
    }

    @MainActor
    private func refreshLoop() async {
        while !Task.isCancelled {
            refreshDisplayedCues(at: resolvedCurrentTime)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    private func refreshDisplayedCues(at time: Double) {
        let videoSize = project.videoSize.width > 0 && project.videoSize.height > 0
            ? project.videoSize
            : CGSize(width: 1920, height: 1080)
        let scene = project.resolvedSubtitleFrameScene(
            at: time,
            canvasSize: videoSize,
            store: store
        )
        guard scene != displayedScene else { return }
        displayedScene = scene
    }

}
