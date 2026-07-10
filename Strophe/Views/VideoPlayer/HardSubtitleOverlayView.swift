import Combine
import SwiftUI

struct HardSubtitleOverlayView: View {
    @ObservedObject var project: SubtitleProject
    @ObservedObject private var store = StyleAndGroupStore.shared
    @State private var displayedCues: [ResolvedSubtitleCue] = []

    var body: some View {
        GeometryReader { proxy in
            let videoSize = project.videoSize.width > 0 && project.videoSize.height > 0
                ? project.videoSize
                : CGSize(width: 1920, height: 1080)
            let displayScale = proxy.size.height / videoSize.height

            ZStack {
                ForEach(displayedCues) { cue in
                    let placementRect = SubtitlePlacementMetrics.placementRect(
                        for: videoSize,
                        style: cue.style
                    )

                    HardSubtitleBitmapView(
                        text: cue.text,
                        style: cue.style,
                        canvasSize: videoSize,
                        displayScale: displayScale
                    )
                        .frame(
                            width: placementRect.width * displayScale,
                            height: placementRect.height * displayScale,
                            alignment: cue.style.alignment.swiftUIAlignment
                        )
                        .position(
                            x: placementRect.midX * displayScale,
                            y: placementRect.midY * displayScale
                        )
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.08), value: displayedCues)
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
        let cues = project.resolvedSubtitleCues(at: time, store: store)
        guard cues != displayedCues else { return }
        displayedCues = cues
    }

}
