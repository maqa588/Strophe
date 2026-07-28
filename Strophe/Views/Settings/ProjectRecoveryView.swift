import SwiftUI

struct ProjectRecoveryView: View {
    @ObservedObject var project: SubtitleProject

    @State private var snapshots: [ProjectBackupSnapshot] = []
    @State private var pendingSnapshot: ProjectBackupSnapshot?
    @State private var isRestoring = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if snapshots.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "project_recovery_empty"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.stropheText)
                    Text(String(localized: "project_recovery_empty_description"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(snapshots) { snapshot in
                            snapshotRow(snapshot)
                        }
                    } header: {
                        Text(String(localized: "project_recovery_snapshots"))
                    } footer: {
                        Text(String(localized: "project_recovery_footer"))
                    }
                }
            }
        }
        .overlay {
            if isRestoring {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    ProgressView(String(localized: "project_recovery_restoring"))
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .inlineNavigationTitle(String(localized: "project_recovery"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    refresh()
                } label: {
                    Label(
                        String(localized: "project_recovery_refresh"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(isRestoring)
            }
        }
        .task {
            refresh()
        }
        .confirmationDialog(
            String(localized: "project_recovery_confirm_title"),
            isPresented: Binding(
                get: { pendingSnapshot != nil },
                set: { if !$0 { pendingSnapshot = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingSnapshot {
                Button(String(localized: "project_recovery_restore_action"), role: .destructive) {
                    restore(pendingSnapshot)
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {
                pendingSnapshot = nil
            }
        } message: {
            Text(String(localized: "project_recovery_confirm_message"))
        }
        .alert(
            String(localized: "project_recovery_failed"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(String(localized: "ok"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func snapshotRow(_ snapshot: ProjectBackupSnapshot) -> some View {
        HStack(spacing: 14) {
            Image(systemName: snapshot.projectID == project.projectIdentifier
                  ? "clock.arrow.circlepath"
                  : "archivebox")
                .font(.title3)
                .foregroundStyle(
                    snapshot.projectID == project.projectIdentifier
                        ? Color.stropheAccent
                        : .secondary
                )
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.createdAt.formatted(date: .abbreviated, time: .standard))
                    .font(.headline)
                    .foregroundStyle(Color.stropheText)

                HStack(spacing: 8) {
                    Text(snapshot.sourceFileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(snapshot.byteCount), countStyle: .file))
                    Text(String(snapshot.projectID.uuidString.prefix(8)))
                        .monospaced()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            Button(String(localized: "project_recovery_restore_action")) {
                pendingSnapshot = snapshot
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRestoring)
        }
        .padding(.vertical, 5)
    }

    private func refresh() {
        snapshots = ProjectBackupStore.snapshots()
    }

    private func restore(_ snapshot: ProjectBackupSnapshot) {
        pendingSnapshot = nil
        isRestoring = true
        Task { @MainActor in
            defer { isRestoring = false }
            do {
                let recovered = try ProjectBackupStore.load(snapshot)
                try await project.loadStropheData(recovered, from: nil)
                project.setDocumentName(String(localized: "project_recovery_recovered_name"))
                project.notifyChange()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
