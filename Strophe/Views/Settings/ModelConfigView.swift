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
    @State private var showModelFolderImporter = false
    @State private var showStorageFolderPicker = false
    @State private var errorMessage: String? = nil
    @State private var showError = false
    @State private var hfTokenDraft: String = ""
    @State private var showHfTokenSaved = false

    var body: some View {
        Form {
            #if os(macOS)
            // MARK: - Storage Location Section
            Section {
                storagePicker
            } header: {
                Text("模型存储位置")
            } footer: {
                Text("选择外置硬盘可节省内置 SSD 空间，下载时模型会直接写入该目录。")
            }

            // MARK: - Local Import Section
            Section {
                Button(action: { showModelFolderImporter = true }) {
                    Label {
                        Text("从本地文件夹导入模型...")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.stropheAccent)
                    } icon: {
                        Image(systemName: "folder.badge.plus")
                            .foregroundStyle(Color.stropheAccent)
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("本地手动导入")
            }
            #endif

            // MARK: - HF Token Section
            Section {
                hfTokenSection
            } footer: {
                Text("部分模型属于受限仓库，需要 Hugging Face 访问令牌才能下载。可前往 huggingface.co/settings/tokens 获取。")
            }

            // MARK: - Model List Section
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
                Text("可用模型库")
            }

            if type == .whisper {
                Section {
                    let vadType = AIKitType.vad
                    let presets = LocalModelManager.presets(for: vadType)
                    let downloadedSet = modelManager.downloadedSet(for: vadType)
                    ForEach(presets, id: \.name) { model in
                        let modelId = "\(vadType.rawValue)_\(model.name)"
                        let isDownloaded = downloadedSet.contains(model.name)
                        let isDownloading = modelManager.activeDownloads.contains(modelId)
                        let progress = modelManager.downloadProgresses[modelId] ?? 0.0
                        modelRow(
                            model: model,
                            typeOverride: vadType,
                            isDownloaded: isDownloaded,
                            isDownloading: isDownloading,
                            progress: progress,
                            showsRepositoryLink: true
                        )
                    }
                } header: {
                    Text("语音活动检测 (VAD)")
                } footer: {
                    Text("自动字幕会先用 VAD 生成 Speech Islands，再交给 ASR 与 ForcedAligner。")
                }
            }
        }
        .formStyle(.grouped)
        .background(Color.stropheBackground)
        .navigationTitle(type.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            hfTokenDraft = modelManager.huggingFaceToken
        }
        // Model folder importer (both platforms)
        .fileImporter(
            isPresented: $showModelFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result: result)
        }
        // Storage location picker (pure SwiftUI, both platforms)
        .fileImporter(
            isPresented: $showStorageFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleStoragePick(result: result)
        }
        .alert("错误", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            if let msg = errorMessage { Text(msg) }
        }
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
                    Text(hasExternal ? "外置硬盘" : "内置沙盒")
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
                    Label("选择存储目录", systemImage: "folder.badge.plus")
                        .font(.callout)
                }
                .buttonStyle(.bordered)

                if hasExternal {
                    Button(role: .destructive) {
                        modelManager.clearExternalStorageBookmark()
                    } label: {
                        Label("恢复默认", systemImage: "arrow.uturn.backward")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                }
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

    // MARK: - HF Token Section

    @ViewBuilder
    private var hfTokenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SecureField("hf_...", text: $hfTokenDraft)
                    .textContentType(.password)
                    .font(.system(.body, design: .monospaced))

                Button("保存") {
                    modelManager.huggingFaceToken = hfTokenDraft
                    showHfTokenSaved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showHfTokenSaved = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(hfTokenDraft == modelManager.huggingFaceToken)

                if showHfTokenSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }

            if !modelManager.huggingFaceToken.isEmpty {
                Label("Token 已保存", systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
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
                        Text("\(Int(progress * 100))%")
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

    // MARK: - Import Handler

    private func handleImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try modelManager.importModel(type: type, from: url)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
            showError = true
        }
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
