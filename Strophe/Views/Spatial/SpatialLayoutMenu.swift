//
//  SpatialLayoutMenu.swift
//  Strophe
//
//  visionOS only: layout presets and the placeholder shown when a module has
//  been moved into its own window.
//

#if os(visionOS)
import SwiftUI

struct SpatialLayoutMenu: View {
    @EnvironmentObject private var workspace: SpatialWorkspaceModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some View {
        Menu {
            Section("vp_window_section") {
                Button {
                    toggle(windowID: SpatialWindowID.video, isOpen: workspace.isVideoDetached)
                } label: {
                    Label("vp_window_video", systemImage: "play.rectangle")
                }

                Button {
                    toggle(windowID: SpatialWindowID.timeline, isOpen: workspace.isTimelineDetached)
                } label: {
                    Label("vp_window_timeline", systemImage: "timeline.selection")
                }

                Button {
                    toggle(windowID: SpatialWindowID.teleprompter, isOpen: workspace.isTeleprompterOpen)
                } label: {
                    Label("vp_window_teleprompter", systemImage: "text.bubble")
                }

                Button {
                    toggle(windowID: SpatialWindowID.cinema, isOpen: workspace.isCinemaOpen)
                } label: {
                    Label("vp_window_cinema", systemImage: "film")
                }

                Button {
                    toggle(windowID: SpatialWindowID.volume, isOpen: workspace.isVolumeOpen)
                } label: {
                    Label("vp_window_volume", systemImage: "cube")
                }

                Button {
                    Task { _ = await openImmersiveSpace(id: SpatialWindowID.immersive) }
                } label: {
                    Label("vp_immersive_enter", systemImage: "visionpro")
                }
            }

            Section("vp_layout_section") {
                ForEach(SpatialWorkspaceModel.Mode.allCases) { mode in
                    Button {
                        apply(mode)
                    } label: {
                        Label(mode.title, systemImage: mode.systemImage)
                    }
                }
            }

            if let firstStyle = StyleAndGroupStore.shared.styles.first {
                Section("vp_style_section") {
                    Button {
                        openWindow(id: SpatialWindowID.style, value: firstStyle.id)
                    } label: {
                        Label("vp_open_style_window", systemImage: "slider.horizontal.3")
                    }
                }
            }
        } label: {
            Label("vp_workspace_menu", systemImage: "square.grid.3x3")
        }
    }

    private func toggle(windowID: String, isOpen: Bool) {
        if isOpen {
            dismissWindow(id: windowID)
        } else {
            openWindow(id: windowID)
        }
    }

    private func openIfNeeded(windowID: String, isOpen: Bool) {
        guard !isOpen else { return }
        openWindow(id: windowID)
    }

    private func closeIfNeeded(windowID: String, isOpen: Bool) {
        guard isOpen else { return }
        dismissWindow(id: windowID)
    }

    private func apply(_ mode: SpatialWorkspaceModel.Mode) {
        workspace.mode = mode

        switch mode {
        case .combined:
            closeIfNeeded(windowID: SpatialWindowID.video, isOpen: workspace.isVideoDetached)
            closeIfNeeded(windowID: SpatialWindowID.timeline, isOpen: workspace.isTimelineDetached)
            closeIfNeeded(windowID: SpatialWindowID.teleprompter, isOpen: workspace.isTeleprompterOpen)
            closeIfNeeded(windowID: SpatialWindowID.cinema, isOpen: workspace.isCinemaOpen)

        case .review:
            closeIfNeeded(windowID: SpatialWindowID.timeline, isOpen: workspace.isTimelineDetached)
            closeIfNeeded(windowID: SpatialWindowID.teleprompter, isOpen: workspace.isTeleprompterOpen)
            openIfNeeded(windowID: SpatialWindowID.video, isOpen: workspace.isVideoDetached)

        case .workbench:
            openIfNeeded(windowID: SpatialWindowID.video, isOpen: workspace.isVideoDetached)
            openIfNeeded(windowID: SpatialWindowID.timeline, isOpen: workspace.isTimelineDetached)
            openIfNeeded(windowID: SpatialWindowID.teleprompter, isOpen: workspace.isTeleprompterOpen)

        case .styleLab:
            openIfNeeded(windowID: SpatialWindowID.video, isOpen: workspace.isVideoDetached)
            for style in StyleAndGroupStore.shared.styles.prefix(2) {
                openWindow(id: SpatialWindowID.style, value: style.id)
            }
        }
    }
}

struct DetachedModulePlaceholder: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let windowID: String

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                dismissWindow(id: windowID)
            } label: {
                Label("vp_bring_back", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
