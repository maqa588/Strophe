//
//  ModelConfigView.swift
//  Strophe
//
//  Created by Antigravity on 2026/05/28.
//

import SwiftUI
import UniformTypeIdentifiers

struct ModelConfigView: View {
    let type: AIKitType

    @StateObject private var modelManager = LocalModelManager.shared
    @State private var showStorageFolderPicker = false
    @State private var errorMessage: String? = nil
    @State private var showError = false

    var body: some View {
        Form {
            if AIBackendClient.isLocalDeviceSupported {
                supportedModelConfigContent
            } else {
                Section {
                    LocalAIUnsupportedView()
                        .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16))
                }
            }
        }
        .formStyle(.grouped)
        .background(Color.stropheBackground)
        .navigationTitle(LocalizedStringKey(type.title))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Storage location picker (pure SwiftUI, both platforms)
        .fileImporter(
            isPresented: $showStorageFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleStoragePick(result: result)
        }
        .alert("error", isPresented: $showError) {
            Button("ok", role: .cancel) {}
        } message: {
            if let msg = errorMessage { Text(msg) }
        }
    }

    @ViewBuilder
    private var supportedModelConfigContent: some View {
        #if os(macOS)
        Section {
            storagePicker
        } header: {
            Text("model_storage_location")
        } footer: {
            Text("selecting_an_external_hard_drive")
        }

        #endif

        Section {
            let presets = LocalModelManager.presets(for: type)
            let downloadedSet = modelManager.downloadedSet(for: type)
            ForEach(presets, id: \.name) { model in
                let modelId = "\(type.rawValue)_\(model.name)"
                let isDownloaded = downloadedSet.contains(model.name)
                let isDownloading = modelManager.activeDownloads.contains(modelId)
                let progress = modelManager.downloadProgresses[modelId] ?? 0.0
                modelRow(
                    model: model,
                    isDownloaded: isDownloaded,
                    isDownloading: isDownloading,
                    progress: progress
                )
            }
        } header: {
            Text("available_models_library")
        }

        #if os(iOS)
        if let storageError = modelManager.storageAccessError {
            Section {
                Label(storageError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        #endif

    }

    // MARK: - Storage Picker

    @ViewBuilder
    private var storagePicker: some View {
        let hasExternal = modelManager.resolvedExternalURL() != nil
        let summary = storageDisplayPath

        VStack(alignment: .leading, spacing: 12) {
            // Current location card
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: hasExternal ? "externaldrive.fill" : "internaldrive.fill")
                    .font(.title2)
                    .foregroundStyle(hasExternal ? Color.stropheAccent : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(hasExternal ? "external_hard_drive" : "built_in_sandbox")
                        .font(.subheadline.weight(.semibold))
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Action buttons — wrap gracefully
            FlowHStack(spacing: 8) {
                Button {
                    showStorageFolderPicker = true
                } label: {
                    Label("select_storage_directory", systemImage: "folder.badge.plus")
                        .font(.callout)
                }
                .buttonStyle(.bordered)

                if hasExternal {
                    Button(role: .destructive) {
                        modelManager.clearExternalStorageBookmark()
                    } label: {
                        Label("restore_defaults", systemImage: "arrow.uturn.backward")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let storageError = modelManager.storageAccessError {
                Label(storageError, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    /// Shortens the path to the last two components for display.
    private var storageDisplayPath: String {
        let full = modelManager.storageSummary
        let components = full.split(separator: "/", omittingEmptySubsequences: true)
        if components.count <= 3 {
            return full
        }
        // Show "…/penultimate/last"
        let tail = components.suffix(2).joined(separator: "/")
        return "…/" + tail
    }

    // MARK: - Model Row

    @ViewBuilder
    private func modelRow(
        model: AIModelInfo,
        typeOverride: AIKitType? = nil,
        isDownloaded: Bool,
        isDownloading: Bool,
        progress: Double,
        showsRepositoryLink: Bool = false
    ) -> some View {
        let rowType = typeOverride ?? type
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                // Name + size tag
                Text(model.name)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.stropheText)
                    .lineLimit(1)
                    .layoutPriority(1)

                Text(model.size)
                    .font(.system(.caption2, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.stropheSecondaryBackground)
                    .cornerRadius(6)
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Spacer(minLength: 4)

                // State: downloading / downloaded / download button
                if isDownloading {
                    VStack(alignment: .trailing, spacing: 3) {
                        ProgressView(value: progress)
                            .frame(width: 72)
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } else if isDownloaded {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.title3)
                        Button {
                            modelManager.deleteModel(type: rowType, modelName: model.name)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(Color.stropheAccent)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Button {
                        Task { await modelManager.downloadModel(type: rowType, modelName: model.name) }
                    } label: {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.title3)
                            .foregroundStyle(Color.stropheAccent)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Description below — never competes with the trailing controls
            Text(model.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showsRepositoryLink, let hfId = modelManager.huggingFaceModelId(for: model.name),
               let url = URL(string: "https://huggingface.co/\(hfId)") {
                Link(destination: url) {
                    Label(hfId, systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(Color.stropheAccent)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Storage Folder Pick Handler (pure SwiftUI, cross-platform)

    private func handleStoragePick(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try modelManager.saveExternalStorageBookmark(for: url)
            } catch {
                errorMessage = "保存存储目录权限失败：\(error.localizedDescription)"
                showError = true
            }
        case .failure(let error):
            // User cancelled is a URLError with .cancelled code — ignore silently
            let nsErr = error as NSError
            if nsErr.code != NSUserCancelledError {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

// MARK: - FlowHStack: wraps buttons to next line when they overflow

/// A simple flow-layout HStack that wraps its children when they exceed the available width.
/// Uses `ViewThatFits` on iOS 16+ for the common 1-button case; falls back to a plain HStack
/// for wider layouts so buttons never clip off-screen.
private struct FlowHStack<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { content() }
            VStack(alignment: .leading, spacing: spacing) { content() }
        }
    }
}
