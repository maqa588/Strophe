//
//  SpatialSceneRoots.swift
//  Strophe
//
//  visionOS scene roots. Each root owns exactly one module and reports its
//  open/closed state to SpatialWorkspaceModel so the main editor can swap in
//  placeholders instead of hosting duplicate player surfaces.
//

#if os(visionOS)
import AVKit
import RealityKit
import SwiftUI
import UIKit

// MARK: - Video

struct VideoWindowRoot: View {
    @ObservedObject var project: SubtitleProject
    @EnvironmentObject private var workspace: SpatialWorkspaceModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VideoPlayerView(project: project, onImportMedia: {})
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.clear)
            .toolbar {
                ToolbarItemGroup(placement: .bottomOrnament) {
                    Button {
                        project.seekDelta(-5)
                    } label: {
                        Image(systemName: "gobackward.5")
                    }
                    .accessibilityLabel(Text("vp_seek_back_5"))

                    Button {
                        project.togglePlayback()
                    } label: {
                        Image(systemName: project.playbackRate > 0 ? "pause.fill" : "play.fill")
                    }
                    .accessibilityLabel(Text(project.playbackRate > 0 ? "vp_pause" : "vp_play"))

                    Button {
                        project.seekDelta(5)
                    } label: {
                        Image(systemName: "goforward.5")
                    }
                    .accessibilityLabel(Text("vp_seek_forward_5"))

                    Button {
                        dismissWindow(id: SpatialWindowID.video)
                    } label: {
                        Image(systemName: "rectangle.on.rectangle.slash")
                    }
                    .accessibilityLabel(Text("vp_video_return_embedded"))
                }
            }
            .onAppear { workspace.isVideoDetached = true }
            .onDisappear { workspace.isVideoDetached = false }
    }
}

// MARK: - Timeline

struct TimelineWindowRoot: View {
    @ObservedObject var project: SubtitleProject
    @EnvironmentObject private var workspace: SpatialWorkspaceModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            WaveformTimelineView(project: project)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.clear)
        .toolbar {
            ToolbarItemGroup(placement: .bottomOrnament) {
                Button {
                    project.togglePlayback()
                } label: {
                    Image(systemName: project.playbackRate > 0 ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(Text(project.playbackRate > 0 ? "vp_pause" : "vp_play"))

                Button {
                    dismissWindow(id: SpatialWindowID.timeline)
                } label: {
                    Image(systemName: "rectangle.on.rectangle.slash")
                }
                .accessibilityLabel(Text("vp_close_window"))
            }
        }
        .onAppear { workspace.isTimelineDetached = true }
        .onDisappear { workspace.isTimelineDetached = false }
    }
}

// MARK: - Teleprompter

struct TeleprompterWindowRoot: View {
    @ObservedObject var project: SubtitleProject
    @EnvironmentObject private var workspace: SpatialWorkspaceModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var fontSize: CGFloat = 72

    private var currentText: String {
        let value = project.currentSubtitleText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value! : "—"
    }

    private var nextText: String? {
        let time = project.currentTime
        return project.items
            .filter { ($0.startTime ?? .greatestFiniteMagnitude) > time }
            .min(by: { ($0.startTime ?? 0) < ($1.startTime ?? 0) })?
            .text
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            Text(currentText)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.4)
                .shadow(color: .black.opacity(0.6), radius: 8, y: 3)

            if let nextText, !nextText.isEmpty {
                VStack(spacing: 6) {
                    Text("vp_teleprompter_next")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(nextText)
                        .font(.system(size: max(20, fontSize * 0.34)))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55))
        .toolbar {
            ToolbarItemGroup(placement: .bottomOrnament) {
                Button {
                    fontSize = max(32, fontSize - 8)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .accessibilityLabel(Text("vp_font_smaller"))

                Button {
                    fontSize = min(200, fontSize + 8)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .accessibilityLabel(Text("vp_font_larger"))

                Button {
                    project.togglePlayback()
                } label: {
                    Image(systemName: project.playbackRate > 0 ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(Text(project.playbackRate > 0 ? "vp_pause" : "vp_play"))

                Button {
                    dismissWindow(id: SpatialWindowID.teleprompter)
                } label: {
                    Image(systemName: "rectangle.on.rectangle.slash")
                }
                .accessibilityLabel(Text("vp_close_window"))
            }
        }
        .onAppear { workspace.isTeleprompterOpen = true }
        .onDisappear { workspace.isTeleprompterOpen = false }
    }
}

// MARK: - Style

struct StyleWindowRoot: View {
    @ObservedObject var project: SubtitleProject
    let styleID: UUID
    @ObservedObject private var store = StyleAndGroupStore.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var isPresented = true
    @State private var selectedStyleID: UUID?

    private var styleExists: Bool {
        store.styles.contains { $0.id == styleID }
    }

    var body: some View {
        Group {
            if styleExists {
                StyleEditSheet(
                    isPresented: $isPresented,
                    selectedStyleId: $selectedStyleID,
                    project: project,
                    appliesChangesLive: true
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "paintpalette")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("vp_style_unavailable")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 400, minHeight: 560)
        .onAppear { selectedStyleID = styleID }
        .stropheOnChange(of: isPresented) { presented in
            if !presented {
                dismissWindow(id: SpatialWindowID.style, value: styleID)
            }
        }
        .stropheOnChange(of: store.styles.map(\.id)) { ids in
            if !ids.contains(styleID) {
                dismissWindow(id: SpatialWindowID.style, value: styleID)
            }
        }
    }
}

// MARK: - Cinema (spatial video review)

struct CinemaWindowRoot: View {
    @ObservedObject var project: SubtitleProject
    @EnvironmentObject private var workspace: SpatialWorkspaceModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("vp_cinema_no_media")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 405)
        .toolbar {
            ToolbarItemGroup(placement: .bottomOrnament) {
                Button {
                    player?.isMuted.toggle()
                } label: {
                    Image(systemName: (player?.isMuted ?? false) ? "speaker.slash" : "speaker.wave.2")
                }
                .accessibilityLabel(Text("vp_toggle_mute"))

                Button {
                    dismissWindow(id: SpatialWindowID.cinema)
                } label: {
                    Image(systemName: "rectangle.on.rectangle.slash")
                }
                .accessibilityLabel(Text("vp_close_window"))
            }
        }
        .onAppear {
            workspace.isCinemaOpen = true
            guard player == nil, let url = project.videoURL else { return }
            // Only one decoder should be active: hand playback over to the
            // native AVPlayer used by the cinema window.
            project.pause()
            let nextPlayer = AVPlayer(url: url)
            player = nextPlayer
            nextPlayer.play()
        }
        .onDisappear {
            workspace.isCinemaOpen = false
            player?.pause()
            player = nil
        }
    }
}

// MARK: - Volumetric preview

struct VolumePreviewRoot: View {
    @ObservedObject var project: SubtitleProject
    @EnvironmentObject private var workspace: SpatialWorkspaceModel

    var body: some View {
        RealityView { content, attachments in
            let panel = ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(0.8, 0.45, 0.02), cornerRadius: 0.02),
                materials: [SimpleMaterial(color: UIColor.black.withAlphaComponent(0.85), isMetallic: false)]
            )
            content.add(panel)

            if let label = attachments.entity(for: "subtitle") {
                label.position = SIMD3<Float>(0, 0, 0.02)
                content.add(label)
            }
        } attachments: {
            Attachment(id: "subtitle") {
                Text(project.currentSubtitleText ?? "—")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(width: 720, height: 360)
                    .padding(12)
            }
        }
        .onAppear { workspace.isVolumeOpen = true }
        .onDisappear { workspace.isVolumeOpen = false }
    }
}

// MARK: - Immersive cinema space

struct ImmersiveCinemaView: View {
    @ObservedObject var project: SubtitleProject

    var body: some View {
        RealityView { content, attachments in
            let screen = ModelEntity(
                mesh: .generatePlane(width: 4.0, height: 2.25, cornerRadius: 0.06),
                materials: [SimpleMaterial(color: UIColor.black, isMetallic: false)]
            )
            screen.position = SIMD3<Float>(0, 1.5, -2.6)
            content.add(screen)

            if let label = attachments.entity(for: "subtitle") {
                label.position = SIMD3<Float>(0, 0.55, -2.58)
                content.add(label)
            }
        } attachments: {
            Attachment(id: "subtitle") {
                Text(project.currentSubtitleText ?? "")
                    .font(.system(size: 88, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(width: 1100)
                    .padding(20)
            }
        }
    }
}
#endif
