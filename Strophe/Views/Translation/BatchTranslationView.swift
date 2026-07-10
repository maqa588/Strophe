import SwiftUI

struct BatchTranslationView: View {
    @ObservedObject var project: SubtitleProject

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var groupStore = StyleAndGroupStore.shared
    @ObservedObject private var settings = TranslationSettingsStore.shared

    @State private var sourceGroupID: UUID
    @State private var targetGroupID: UUID
    @State private var sourceLanguage: SubtitleLanguage = .auto
    @State private var targetLanguage: SubtitleLanguage = .chineseSimplified
    @State private var progress: Double = 0
    @State private var completedCount = 0
    @State private var isRunning = false
    @State private var completionMessage: String?
    @State private var errorMessage: String?
    @State private var translationTask: Task<Void, Never>?

    init(project: SubtitleProject) {
        self.project = project
        let groups = StyleAndGroupStore.shared.sortedGroups
        let source = StyleAndGroupStore.shared.activeGroupID ?? groups.first?.id ?? UUID()
        let target = groups.first(where: { $0.id != source && ($0.role == .translatedDraft || $0.role == .secondaryLanguage) })?.id
            ?? groups.first(where: { $0.id != source })?.id
            ?? source
        _sourceGroupID = State(initialValue: source)
        _targetGroupID = State(initialValue: target)
    }

    private var sourceItems: [SubtitleItem] {
        project.items
            .filter {
                project.belongsToGroup($0, groupID: sourceGroupID, store: groupStore)
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { ($0.startTime ?? .greatestFiniteMagnitude, $0.originalIndex) < ($1.startTime ?? .greatestFiniteMagnitude, $1.originalIndex) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("翻译范围") {
                    Picker("原文小组", selection: $sourceGroupID) {
                        ForEach(groupStore.sortedGroups) { group in Text(group.name).tag(group.id) }
                    }
                    Picker("译文小组", selection: $targetGroupID) {
                        ForEach(groupStore.sortedGroups.filter { $0.id != sourceGroupID }) { group in Text(group.name).tag(group.id) }
                    }
                    LabeledContent("字幕数量", value: "\(sourceItems.count) 条")
                }

                Section("语言") {
                    Picker("原语言", selection: $sourceLanguage) {
                        ForEach(SubtitleLanguage.allCases) { language in Text(language.title).tag(language) }
                    }
                    Picker("目标语言", selection: $targetLanguage) {
                        ForEach(SubtitleLanguage.allCases.filter { $0 != .auto }) { language in Text(language.title).tag(language) }
                    }
                }

                TranslationProviderSettingsSection(settings: settings)

                if isRunning || completedCount > 0 {
                    Section("进度") {
                        ProgressView(value: progress) {
                            Text(isRunning ? "正在批量翻译" : "翻译完成")
                        } currentValueLabel: {
                            Text("\(completedCount) / \(sourceItems.count)")
                                .monospacedDigit()
                        }
                    }
                }

                if let completionMessage {
                    Section {
                        Label(completionMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("批量翻译字幕")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        translationTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isRunning {
                        Button("取消", role: .destructive) {
                            translationTask?.cancel()
                        }
                    } else {
                        Button("开始翻译", action: startTranslation)
                            .buttonStyle(.borderedProminent)
                            .disabled(sourceItems.isEmpty || targetGroupID == sourceGroupID)
                    }
                }
            }
        }
        .frame(minWidth: 580, minHeight: 620)
        .onDisappear { translationTask?.cancel() }
        .alert("批量翻译失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private func startTranslation() {
        settings.save()
        let configuration = settings.configuration
        let requests = sourceItems.map { TranslationRequestItem(id: $0.id, text: $0.text) }
        guard !requests.isEmpty else { return }

        isRunning = true
        progress = 0
        completedCount = 0
        completionMessage = nil
        errorMessage = nil

        translationTask = Task {
            do {
                var translatedByID: [UUID: String] = [:]
                for start in stride(from: 0, to: requests.count, by: 5) {
                    try Task.checkCancellation()
                    let chunk = Array(requests[start..<min(start + 5, requests.count)])
                    let translated = try await TranslationLLMClient.shared.translateBatch(
                        chunk,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        configuration: configuration
                    )
                    for result in translated {
                        translatedByID[result.id] = result.translation
                    }
                    completedCount = min(start + chunk.count, requests.count)
                    progress = Double(completedCount) / Double(requests.count)
                }

                try Task.checkCancellation()
                project.applyBatchTranslations(
                    translatedByID,
                    targetGroupID: targetGroupID,
                    languageCode: targetLanguage.rawValue
                )
                completionMessage = "已将 \(translatedByID.count) 条译文写入 \(groupStore.group(id: targetGroupID)?.name ?? "目标小组")。"
            } catch is CancellationError {
                completionMessage = "翻译已取消，未写入未完成的结果。"
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunning = false
            translationTask = nil
        }
    }
}
