import SwiftUI

struct SubtitleTranslationAssistantView: View {
    @ObservedObject var project: SubtitleProject
    let startItemID: UUID?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var groupStore = StyleAndGroupStore.shared
    @ObservedObject private var settings = TranslationSettingsStore.shared
    @ObservedObject private var phrasesStore = CommonTranslationPhrasesStore.shared

    @State private var sourceGroupID: UUID
    @State private var targetGroupID: UUID
    @State private var sourceLanguage: SubtitleLanguage = .auto
    @State private var targetLanguage: SubtitleLanguage = .chineseSimplified
    @State private var currentIndex = 0
    @State private var translationText = ""
    @State private var translationSelection = NSRange(location: 0, length: 0)
    @State private var dictionaryTerm = ""
    @State private var referenceDefinition: AppleDictionaryDefinition?
    @State private var referenceMessage = ""
    @State private var newPhrase = ""
    @State private var isTranslating = false
    @State private var isShowingServiceSettings = false
    @State private var isShowingReference = true
    @State private var errorMessage: String?
    #if os(iOS)
    @State private var dictionarySheetTerm: DictionaryTerm?
    #endif

    init(project: SubtitleProject, startItemID: UUID? = nil) {
        self.project = project
        self.startItemID = startItemID
        let groups = StyleAndGroupStore.shared.sortedGroups
        let sourceItem = startItemID.flatMap { id in project.items.first(where: { $0.id == id }) }
        let source = sourceItem?.groupID ?? StyleAndGroupStore.shared.activeGroupID ?? groups.first?.id ?? UUID()
        let target = groups.first(where: { $0.id != source && ($0.role == .translatedDraft || $0.role == .secondaryLanguage) })?.id
            ?? groups.first(where: { $0.id != source })?.id
            ?? source
        _sourceGroupID = State(initialValue: source)
        _targetGroupID = State(initialValue: target)
    }

    private var sourceItems: [SubtitleItem] {
        project.items
            .filter { project.belongsToGroup($0, groupID: sourceGroupID, store: groupStore) }
            .sorted { lhs, rhs in
                switch (lhs.startTime, rhs.startTime) {
                case let (a?, b?): return a == b ? lhs.originalIndex < rhs.originalIndex : a < b
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.originalIndex < rhs.originalIndex
                }
            }
    }

    private var currentItem: SubtitleItem? {
        sourceItems.indices.contains(currentIndex) ? sourceItems[currentIndex] : nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if sourceItems.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "captions.bubble")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("no_original_subtitles_in_group").font(.headline)
                        Text("select_original_group_hint")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 0) {
                            assistantPane
                                .frame(minWidth: 520)
                            if isShowingReference {
                                Divider()
                                referencePane
                                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
                            }
                        }
                        ScrollView {
                            VStack(spacing: 0) {
                                assistantPane
                                if isShowingReference {
                                    Divider().padding(.vertical, 8)
                                    referencePane
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("subtitle_translation_assistant")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        isShowingReference.toggle()
                    } label: {
                        Label("reference_area", systemImage: "sidebar.trailing")
                    }
                    Button {
                        isShowingServiceSettings = true
                    } label: {
                        Label("translation_service", systemImage: "gearshape")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 680, minHeight: 560)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .onAppear(perform: initializePosition)
        .stropheOnChange(of: sourceGroupID) { _ in
            currentIndex = 0
            loadCurrentTranslation()
        }
        .stropheOnChange(of: targetGroupID) { _ in loadCurrentTranslation() }
        .sheet(isPresented: $isShowingServiceSettings) {
            NavigationStack {
                TranslationConfigView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("storage") {
                                settings.save()
                                isShowingServiceSettings = false
                            }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 540, minHeight: 480)
            #else
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .presentationDetents([.medium, .large])
            #endif
        }
        #if os(iOS)
        .sheet(item: $dictionarySheetTerm) { term in
            AppleReferenceDictionaryView(term: term.value)
                .ignoresSafeArea()
        }
        #endif
        .alert("translation_failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var assistantPane: some View {
        VStack(spacing: 16) {
            groupAndLanguagePickers
            Divider()
            sourceEditor
            translationEditor
            commonPhrases
            operationBar
            statusBar
        }
        .padding(20)
        .background { keyboardShortcutButtons }
    }

    private var groupAndLanguagePickers: some View {
        ViewThatFits(in: .horizontal) {
            groupAndLanguagePickerGrid
            compactGroupAndLanguagePickers
        }
    }

    private var groupAndLanguagePickerGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("original_text_group").foregroundStyle(.secondary)
                Picker("original_text_group", selection: $sourceGroupID) {
                    ForEach(groupStore.sortedGroups) { group in
                        Text(group.name).tag(group.id)
                    }
                }
                .labelsHidden()
                Picker("source_language", selection: $sourceLanguage) {
                    ForEach(SubtitleLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.title)).tag(language)
                    }
                }
                .labelsHidden()
            }
            GridRow {
                Text("translation_group").foregroundStyle(.secondary)
                Picker("translation_group", selection: $targetGroupID) {
                    ForEach(groupStore.sortedGroups.filter { $0.id != sourceGroupID }) { group in
                        Text(group.name).tag(group.id)
                    }
                }
                .labelsHidden()
                Picker("target_language", selection: $targetLanguage) {
                    ForEach(SubtitleLanguage.allCases.filter { $0 != .auto }) { language in
                        Text(LocalizedStringKey(language.title)).tag(language)
                    }
                }
                .labelsHidden()
            }
        }
    }

    private var compactGroupAndLanguagePickers: some View {
        VStack(spacing: 12) {
            LabeledContent("original_text_group") {
                Picker("original_text_group", selection: $sourceGroupID) {
                    ForEach(groupStore.sortedGroups) { group in
                        Text(group.name).tag(group.id)
                    }
                }
                .labelsHidden()
            }
            LabeledContent("source_language") {
                Picker("source_language", selection: $sourceLanguage) {
                    ForEach(SubtitleLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.title)).tag(language)
                    }
                }
                .labelsHidden()
            }
            LabeledContent("translation_group") {
                Picker("translation_group", selection: $targetGroupID) {
                    ForEach(groupStore.sortedGroups.filter { $0.id != sourceGroupID }) { group in
                        Text(group.name).tag(group.id)
                    }
                }
                .labelsHidden()
            }
            LabeledContent("target_language") {
                Picker("target_language", selection: $targetLanguage) {
                    ForEach(SubtitleLanguage.allCases.filter { $0 != .auto }) { language in
                        Text(LocalizedStringKey(language.title)).tag(language)
                    }
                }
                .labelsHidden()
            }
        }
    }

    private var sourceEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("original_text", systemImage: "text.quote")
                    .font(.headline)
                Spacer()
                Text("\(currentItem?.text.count ?? 0) 字符")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    setTranslationText(currentItem?.text ?? "")
                } label: {
                    Image(systemName: "arrow.down")
                }
                .help("copy_original_to_translation")
            }
            Text(currentItem?.text ?? "")
                .font(.title3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                .padding(12)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var translationEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("translation_text", systemImage: "character.bubble")
                    .font(.headline)
                Spacer()
                Text("\(translationText.count) 字符")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(role: .destructive) { clearTranslation() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("clear_translation")
            }
            TranslationTextInput(
                text: $translationText,
                selection: $translationSelection,
                onSubmit: saveAndNext
            )
            .frame(minHeight: 94, maxHeight: 170)
            .padding(.horizontal, 10)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var commonPhrases: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("common_vocabulary").font(.subheadline.weight(.semibold))
                Spacer()
                TextField("add_vocabulary", text: $newPhrase)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 190)
                    .onSubmit(addPhrase)
                Button(action: addPhrase) { Image(systemName: "plus") }
                    .dropDestination(for: String.self) { dropped, _ in
                        for phrase in dropped { phrasesStore.add(phrase) }
                        return !dropped.isEmpty
                    }
                    .help("add_vocabulary_drag_hint")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Array(phrasesStore.phrases.enumerated()), id: \.offset) { index, phrase in
                        Button {
                            insertPhrase(phrase)
                        } label: {
                            HStack(spacing: 5) {
                                if index < 9 {
                                    Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Text(phrase)
                            }
                        }
                        .buttonStyle(.bordered)
                        .contextMenu {
                            Button("delete", role: .destructive) {
                                phrasesStore.remove(at: IndexSet(integer: index))
                            }
                        }
                    }
                }
            }
        }
    }

    private var operationBar: some View {
        HStack(spacing: 10) {
            Button(action: previous) { Label("previous_sentence", systemImage: "chevron.left") }
                .disabled(currentIndex == 0)
            Button(action: saveAndNext) { Label("save_and_next_sentence", systemImage: "chevron.right") }
            Spacer()
            Button(action: lookupCurrentText) { Label("dictionary", systemImage: "books.vertical") }
            Button(action: machineTranslateCurrent) {
                if isTranslating {
                    ProgressView().controlSize(.small)
                } else {
                    Label("translate_full_sentence", systemImage: "sparkles")
                }
            }
            .disabled(isTranslating || currentItem == nil)
            .buttonStyle(.borderedProminent)
            .tint(Color.stropheAccent)
            Button { insertPhrase("[标记]") } label: { Label("mark", systemImage: "bookmark") }
        }
        .labelStyle(.titleAndIcon)
    }

    private var statusBar: some View {
        HStack {
            Text(groupStore.group(id: sourceGroupID)?.name ?? "未指定小组")
            Text("bullet_point")
            Text("\(min(currentIndex + 1, sourceItems.count)) / \(sourceItems.count)")
                .monospacedDigit()
            Spacer()
            Text("return_key_save_and_next")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var keyboardShortcutButtons: some View {
        Group {
            Button("clear_translation") { clearTranslation() }
                .keyboardShortcut(KeyEquivalent(Character("\u{F704}")), modifiers: [])

            ForEach(Array(phrasesStore.phrases.prefix(9).enumerated()), id: \.offset) { index, phrase in
                Button("插入常用词 \(index + 1)") { insertPhrase(phrase) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var referencePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("apple_dictionary", systemImage: "character.book.closed")
                .font(.headline)
            HStack {
                TextField("input_query_word", text: $dictionaryTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(lookupDictionary)
                Button(action: lookupDictionary) { Image(systemName: "magnifyingglass") }
            }
            ScrollView {
                if let referenceDefinition {
                    AppleDictionaryDefinitionView(definition: referenceDefinition)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: referenceMessage.isEmpty ? "text.book.closed" : "questionmark.circle")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text(referenceMessage.isEmpty
                             ? "输入词汇后查询 Apple 词典。"
                             : referenceMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                }
            }
            .scrollIndicators(.visible)
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func initializePosition() {
        if let startItemID, let index = sourceItems.firstIndex(where: { $0.id == startItemID }) {
            currentIndex = index
        }
        loadCurrentTranslation()
    }

    private func loadCurrentTranslation() {
        guard let currentItem else {
            translationText = ""
            return
        }
        setTranslationText(project.translationItem(sourceID: currentItem.id, targetGroupID: targetGroupID)?.text ?? "")
        dictionaryTerm = currentItem.text
        project.scrollTargetID = currentItem.id
    }

    private func saveCurrent() {
        guard let currentItem else { return }
        _ = project.upsertTranslation(
            sourceID: currentItem.id,
            targetGroupID: targetGroupID,
            text: translationText,
            languageCode: targetLanguage.rawValue
        )
    }

    private func saveAndNext() {
        saveCurrent()
        next()
    }

    private func previous() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        loadCurrentTranslation()
    }

    private func next() {
        guard currentIndex + 1 < sourceItems.count else { return }
        currentIndex += 1
        loadCurrentTranslation()
    }

    private func machineTranslateCurrent() {
        guard let currentItem else { return }
        settings.save()
        let configuration = settings.configuration
        isTranslating = true
        Task {
            do {
                let translated = try await TranslationLLMClient.shared.translate(
                    currentItem.text,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    configuration: configuration
                )
                setTranslationText(translated)
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            isTranslating = false
        }
    }

    private func lookupCurrentText() {
        dictionaryTerm = currentItem?.text ?? ""
        lookupDictionary()
    }

    private func lookupDictionary() {
        let term = dictionaryTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        #if os(macOS)
        referenceDefinition = AppleDictionaryService.definition(for: term)
        referenceMessage = referenceDefinition == nil ? "Apple 词典中没有找到“\(term)”的释义。" : ""
        #else
        dictionarySheetTerm = DictionaryTerm(value: term)
        #endif
    }

    private func addPhrase() {
        phrasesStore.add(newPhrase)
        newPhrase = ""
    }

    private func insertPhrase(_ phrase: String) {
        let source = translationText as NSString
        let location = min(max(0, translationSelection.location), source.length)
        let length = min(max(0, translationSelection.length), source.length - location)
        let safeRange = NSRange(location: location, length: length)
        let replacement: String
        if safeRange.length == 0,
           location > 0,
           let previous = UnicodeScalar(source.character(at: location - 1)),
           !CharacterSet.whitespacesAndNewlines.contains(previous) {
            replacement = " \(phrase)"
        } else {
            replacement = phrase
        }
        translationText = source.replacingCharacters(in: safeRange, with: replacement)
        translationSelection = NSRange(location: location + (replacement as NSString).length, length: 0)
    }

    private func setTranslationText(_ value: String) {
        translationText = value
        translationSelection = NSRange(location: (value as NSString).length, length: 0)
    }

    private func clearTranslation() {
        translationText = ""
        translationSelection = NSRange(location: 0, length: 0)
    }
}

#if os(iOS)
import UIKit

private struct DictionaryTerm: Identifiable {
    let value: String
    var id: String { value }
}

private struct AppleReferenceDictionaryView: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ uiViewController: UIReferenceLibraryViewController, context: Context) {}
}
#endif
