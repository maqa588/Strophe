//
//  ContentView+FileHandlers.swift
//  Strophe
//

import SwiftUI
import UniformTypeIdentifiers

extension ContentView {

    // MARK: - File Handlers

    func handleReplaceMedia(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            project.replaceMedia(with: url)
            selectedTab = .editor
            settingsPath.removeAll()
        case .failure(let error):
            fileActionError = error.localizedDescription
        }
    }

    func handleSubtitleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let rawText = try SubtitleEngine.loadRawText(from: url)
                project.importScript(rawText)
                selectedTab = .editor
                settingsPath.removeAll()
            } catch {
                fileActionError = error.localizedDescription
            }
        case .failure(let error):
            fileActionError = error.localizedDescription
        }
    }

    func handleOpenProject(_ result: Result<[URL], Error>) {
        DispatchQueue.main.async {
            guard case .success(let urls) = result, let url = urls.first else { return }
            if hasCurrentProjectContent {
                pendingStropheURL = url
                isShowingOverwriteAlert = true
            } else {
                Task {
                    await openProject(url)
                }
            }
        }
    }

    @MainActor
    func openProject(_ url: URL) async {
        project.isLoadingProject = true
        await Task.yield()
        defer { project.isLoadingProject = false }
        do {
            try await project.importStropheProject(from: url)
            WelcomeRecentProjectsStore.remember(url)
        } catch {
            print("Failed to open project: \(error.localizedDescription)")
        }
    }

    func presentSaveStropheExporter() {
        let base = project.documentDisplayName
        let defaultName = base.isEmpty ? "project" : base
        saveStropheDefaultName = defaultName.hasSuffix(".strophe") ? defaultName : "\(defaultName).strophe"
        if let url = project.projectURL, SubtitleProject.isManagedProjectCacheURL(url) {
            cachedProjectURLPendingPromotion = url
        } else {
            cachedProjectURLPendingPromotion = nil
        }
        isShowingSaveStrophe = true
    }

    func saveProject() {
        if let url = project.projectURL,
           !SubtitleProject.isManagedProjectCacheURL(url) {
            Task {
                do {
                    try await project.saveStrophe(to: url)
                    WelcomeRecentProjectsStore.remember(url)
                } catch {
                    print("⚠️ Failed to save Strophe project: \(error.localizedDescription)")
                }
            }
        } else {
            presentSaveStropheExporter()
        }
    }

    func saveProjectAs() {
        presentSaveStropheExporter()
    }

    var hasCurrentProjectContent: Bool {
        project.videoURL != nil || project.projectURL != nil || !project.items.isEmpty || project.isDirty
    }

    func requestNewProject() {
        if hasCurrentProjectContent {
            isShowingNewProjectAlert = true
        } else {
            createNewProject()
        }
    }

    func createNewProject() {
        project.createNewProject()
        selectedTab = .editor
        settingsPath.removeAll()
    }

    var projectLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "opening_project"))
                    .font(.caption.weight(.semibold))
                Text(String(localized: "loading_subtitles_waveform"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.stropheBorder.opacity(0.35), lineWidth: 1)
            )
        }
    }

    var restoreTimeOverlay: some View {
        ZStack {
            Color.black.opacity(0.24)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text(String(localized: "resume_editing_position_confirm"))
                        .font(.headline)
                        .foregroundStyle(Color.stropheText)

                    Text(String(localized: "jump_to_last_position_confirm"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 16) {
                    Button(String(localized: "do_not_restore")) {
                        dismissRestoreTimePrompt()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(String(localized: "restore_position")) {
                        restorePendingTimelinePosition()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
            .frame(width: 360, height: 160)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.stropheBorder.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        }
    }

    func dismissRestoreTimePrompt() {
        isShowingRestoreTimeAlert = false
    }

    func restorePendingTimelinePosition() {
        project.seek(to: pendingRestoreTime)
        isShowingRestoreTimeAlert = false
    }
}
