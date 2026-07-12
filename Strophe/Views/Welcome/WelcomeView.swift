import SwiftUI
#if os(macOS)
import AppKit
#endif

struct WelcomeView: View {
    let projects: [WelcomeRecentProject]
    let isOpeningProject: Bool
    let onAction: (WelcomeAction) -> Void
    let onRemoveRecentProject: (WelcomeRecentProject) -> Void
    let onDeleteRecentProject: (WelcomeRecentProject) throws -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if usesCompactLayout {
                compactLayout
            } else {
                wideLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .ignoresSafeArea()
        .tint(Color.stropheAccent)
        .overlay {
            if isOpeningProject {
                openingOverlay
            }
        }
    }

    private var usesCompactLayout: Bool {
        #if os(macOS)
        false
        #else
        horizontalSizeClass == .compact
        #endif
    }

    private var wideLayout: some View {
        HStack(spacing: 0) {
            WelcomeActionsPanel(onAction: onAction)
                .frame(minWidth: 430, idealWidth: 540, maxWidth: 560)

            Divider()
                .overlay(Color.stropheBorder.opacity(0.45))

            WelcomeRecentProjectsPanel(
                projects: projects,
                onOpen: { onAction(.openRecent($0)) },
                onRemove: onRemoveRecentProject,
                onDelete: onDeleteRecentProject
            )
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
    }

    private var compactLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                CompactWelcomeActionsPanel(onAction: onAction)

                WelcomeRecentProjectsPanel(
                    projects: projects,
                    onOpen: { onAction(.openRecent($0)) },
                    onRemove: onRemoveRecentProject,
                    onDelete: onDeleteRecentProject,
                    isCompact: true
                )
            }
            .padding(.horizontal, 22)
            .padding(.top, 82)
            .padding(.bottom, 34)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var background: some View {
        ZStack {
            Color.stropheBackground
            LinearGradient(
                colors: [
                    Color.stropheAccent.opacity(0.18),
                    Color.stropheSecondaryBackground.opacity(0.55),
                    Color.stropheBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(0.8)
            Rectangle()
                .fill(.regularMaterial)
        }
        .ignoresSafeArea()
    }

    private var openingOverlay: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "opening_project"))
                    .font(.caption.weight(.semibold))
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.stropheBorder.opacity(0.45), lineWidth: 1)
            )
        }
    }
}

private struct WelcomeActionsPanel: View {
    let onAction: (WelcomeAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                WelcomeBrandMark()

                VStack(alignment: .leading, spacing: 4) {
                    Text("strophe_chinese_name")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text("subtitle_timing_transcription_calibration")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 10) {
                WelcomeActionButton(
                    title: String(localized: "new_subtitle_project"),
                    subtitle: String(localized: "start_from_blank_timeline"),
                    systemImage: "plus.square.on.square"
                ) {
                    onAction(.newProject)
                }

                WelcomeActionButton(
                    title: String(localized: "open_video_audio"),
                    subtitle: String(localized: "auto_create_project_cache"),
                    systemImage: "play.rectangle"
                ) {
                    onAction(.openMedia)
                }

                WelcomeActionButton(
                    title: String(localized: "import_subtitle_file"),
                    subtitle: String(localized: "supported_formats_hint"),
                    systemImage: "captions.bubble"
                ) {
                    onAction(.importSubtitles)
                }

                WelcomeActionButton(
                    title: String(localized: "open_strophe_project"),
                    subtitle: String(localized: "select_strophe_file"),
                    systemImage: "folder"
                ) {
                    onAction(.openProject)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 44)
        .padding(.vertical, 34)
    }
}

private struct CompactWelcomeActionsPanel: View {
    let onAction: (WelcomeAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                WelcomeBrandMark(size: 104)

                VStack(alignment: .leading, spacing: 6) {
                    Text("strophe_chinese_name")
                        .font(.system(size: 58, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text("subtitle_timing_transcription_calibration")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 12) {
                WelcomeActionButton(
                    title: String(localized: "new_subtitle_project"),
                    subtitle: String(localized: "start_from_blank_timeline"),
                    systemImage: "plus.square.on.square",
                    isCompact: true
                ) {
                    onAction(.newProject)
                }

                WelcomeActionButton(
                    title: String(localized: "open_video_audio"),
                    subtitle: String(localized: "auto_create_project_cache"),
                    systemImage: "play.rectangle",
                    isCompact: true
                ) {
                    onAction(.openMedia)
                }

                WelcomeActionButton(
                    title: String(localized: "import_subtitle_file"),
                    subtitle: String(localized: "supported_formats_hint"),
                    systemImage: "captions.bubble",
                    isCompact: true
                ) {
                    onAction(.importSubtitles)
                }

                WelcomeActionButton(
                    title: String(localized: "open_strophe_project"),
                    subtitle: String(localized: "select_strophe_file"),
                    systemImage: "folder",
                    isCompact: true
                ) {
                    onAction(.openProject)
                }
            }
        }
    }
}

private struct WelcomeBrandMark: View {
    var size: CGFloat = 112

    var body: some View {
        Image("AppLogo")
            .resizable()
            .scaledToFill()
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.stropheAccent.opacity(0.28), radius: size * 0.2, y: size * 0.1)
        .accessibilityHidden(true)
    }
}

private struct WelcomeActionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var isCompact = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: isCompact ? 26 : 22, weight: .semibold))
                    .frame(width: isCompact ? 34 : 30)
                    .foregroundStyle(Color.stropheAccent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(isCompact ? .title3.weight(.bold) : .headline)
                        .foregroundStyle(Color.stropheText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text(subtitle)
                        .font(isCompact ? .subheadline : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, isCompact ? 20 : 16)
            .frame(height: isCompact ? 72 : 58)
            .welcomeButtonCard(cornerRadius: isCompact ? 24 : 14, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct WelcomeRecentProjectsPanel: View {
    let projects: [WelcomeRecentProject]
    let onOpen: (WelcomeRecentProject) -> Void
    let onRemove: (WelcomeRecentProject) -> Void
    let onDelete: (WelcomeRecentProject) throws -> Void
    var isCompact = false

    @State private var pendingAction: PendingRecentProjectAction?
    @State private var deletionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(String(localized: "recent_projects"))
                    .font(isCompact ? .largeTitle.weight(.bold) : .title3.weight(.semibold))
                Spacer()
            }

            if projects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(projects) { project in
                            WelcomeRecentProjectRow(
                                project: project,
                                onOpen: { onOpen(project) },
                                onRemove: {
                                    pendingAction = PendingRecentProjectAction(project: project, kind: .removeFromList)
                                },
                                onDelete: {
                                    pendingAction = PendingRecentProjectAction(project: project, kind: .deleteFile)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, isCompact ? 0 : 24)
        .padding(.vertical, isCompact ? 4 : 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(
            actionAlertTitle,
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action in
            switch action.kind {
            case .removeFromList:
                Button(String(localized: "remove_from_list")) {
                    onRemove(action.project)
                    pendingAction = nil
                }
            case .deleteFile:
                Button(String(localized: "delete"), role: .destructive) {
                    do {
                        try onDelete(action.project)
                    } catch {
                        deletionError = error.localizedDescription
                    }
                    pendingAction = nil
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {
                pendingAction = nil
            }
        } message: { action in
            switch action.kind {
            case .removeFromList:
                Text(localizedFormat("remove_from_recent_projects_message", action.project.path))
            case .deleteFile:
                Text(localizedFormat("delete_project_file_message", action.project.path))
            }
        }
        .alert(
            String(localized: "error"),
            isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )
        ) {
            Button(String(localized: "ok")) { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
        }
    }

    private var actionAlertTitle: String {
        guard let pendingAction else {
            return String(localized: "remove_from_list")
        }
        switch pendingAction.kind {
        case .removeFromList:
            return String(localized: "remove_from_recent_projects_confirm")
        case .deleteFile:
            return pendingAction.project.isInManagedProjectCache
                ? String(localized: "delete_cached_project_confirm")
                : String(localized: "delete_project_confirm")
        }
    }

    private func localizedFormat(_ key: String.LocalizationValue, _ argument: String) -> String {
        String(format: String(localized: key), locale: .current, argument)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(String(localized: "no_recent_projects"))
                .font(.headline)
            Text(String(localized: "open_save_project_hint"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 8)
    }
}

private struct WelcomeRecentProjectRow: View {
    let project: WelcomeRecentProject
    let onOpen: () -> Void
    let onRemove: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.stropheAccent)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.name.isEmpty ? String(localized: "unnamed_project") : project.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.stropheText)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(project.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)
                }
            }
            .buttonStyle(.plain)

            Menu {
                #if os(macOS)
                Button(action: revealInFinder) {
                    Label(String(localized: "show_in_finder"), systemImage: "folder")
                }
                Divider()
                #endif

                if !project.isInManagedProjectCache {
                    Button(action: onRemove) {
                        Label(String(localized: "remove_from_list"), systemImage: "xmark")
                    }
                }

                Button(role: .destructive, action: onDelete) {
                    Label(String(localized: "delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.secondary)
                    .frame(width: 28, height: 28)
            }
            .tint(Color.secondary)
            .opacity(isHovering ? 1 : 0.65)
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isHovering ? Color.white.opacity(0.12) : Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.stropheBorder.opacity(isHovering ? 0.5 : 0.25), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
    }

    #if os(macOS)
    private func revealInFinder() {
        let resolvedURL = project.resolvedBookmarkURL() ?? project.url
        NSWorkspace.shared.activateFileViewerSelecting([
            resolvedURL.standardizedFileURL.resolvingSymlinksInPath()
        ])
    }
    #endif
}

private struct PendingRecentProjectAction: Identifiable {
    enum Kind: String {
        case removeFromList
        case deleteFile
    }

    let project: WelcomeRecentProject
    let kind: Kind
    var id: String { "\(kind.rawValue):\(project.id)" }
}

private extension View {
    @ViewBuilder
    func welcomeButtonCard(cornerRadius: CGFloat, isHovering: Bool) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering ? Color.white.opacity(0.12) : Color.white.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.stropheBorder.opacity(isHovering ? 0.5 : 0.25), lineWidth: 1)
            )
    }
}

#Preview {
    WelcomeView(
        projects: [
            WelcomeRecentProject(
                name: "Episode 01",
                path: "/Users/maqa/Movies/Episode 01.strophe",
                lastOpened: .now
            )
        ],
        isOpeningProject: false,
        onAction: { _ in },
        onRemoveRecentProject: { _ in },
        onDeleteRecentProject: { _ in }
    )
}
