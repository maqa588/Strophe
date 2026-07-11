import SwiftUI

struct StropheDocumentEditorView: View {
    @Binding var document: StropheProjectDocument
    let fileURL: URL?

    @StateObject private var project = SubtitleProject()
    @State private var didLoadDocument = false
    @State private var loadErrorMessage: String?

    var body: some View {
        ContentView(project: project, embedsCompactEditorInNavigationStack: false)
            .task(id: fileURL) {
                await loadDocument()
            }
            .onReceive(NotificationCenter.default.publisher(for: .subtitleProjectDidChange)) { _ in
                syncDocumentFromProject()
            }
            .alert(
                String(localized: "cannot_open_project"),
                isPresented: Binding(
                    get: { loadErrorMessage != nil },
                    set: { if !$0 { loadErrorMessage = nil } }
                )
            ) {
                Button(String(localized: "ok"), role: .cancel) {
                    loadErrorMessage = nil
                }
            } message: {
                Text(loadErrorMessage ?? "")
            }
    }

    @MainActor
    private func loadDocument() async {
        didLoadDocument = false
        project.isLoadingProject = true
        defer { project.isLoadingProject = false }

        do {
            try await project.importStropheDocument(document, from: fileURL, startsAutoSave: false)
            if let fileURL {
                WelcomeRecentProjectsStore.remember(fileURL)
            }
            didLoadDocument = true
            syncDocumentFromProject()
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func syncDocumentFromProject() {
        guard didLoadDocument else { return }
        document = project.stropheDocument
    }
}
