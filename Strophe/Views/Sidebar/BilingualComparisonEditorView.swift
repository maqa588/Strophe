//
//  BilingualComparisonEditorView.swift
//  Strophe
//

import SwiftUI

struct BilingualComparisonEditorView: View {
    @ObservedObject var project: SubtitleProject
    @ObservedObject private var store = StyleAndGroupStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var primaryGroupID: UUID?
    @State private var secondaryGroupID: UUID?
    @State private var searchText = ""

    init(project: SubtitleProject) {
        self.project = project
        let groups = StyleAndGroupStore.shared.sortedGroups
        _primaryGroupID = State(
            initialValue: groups.first(where: { $0.role == .normal })?.id ?? groups.first?.id
        )
        _secondaryGroupID = State(
            initialValue: groups.first(where: {
                $0.role == .secondaryLanguage || $0.role == .translatedDraft
            })?.id ?? groups.dropFirst().first?.id
        )
    }

    private var sourceItems: [SubtitleItem] {
        guard let primaryGroupID else { return [] }
        return project.items
            .filter {
                project.belongsToGroup($0, groupID: primaryGroupID, store: store)
                    && $0.parentItemID == nil
                    && SubtitleEditingTools.matches(
                        $0.text,
                        query: searchText,
                        options: SubtitleSearchOptions()
                    )
            }
            .sorted(by: project.stableSubtitleSort)
    }

    var body: some View {
        #if os(macOS)
        macOSContent
        #else
        iOSContent
        #endif
    }

    #if os(macOS)
    private var macOSContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("bilingual_comparison_editor")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.stropheText)

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()
                .background(Color.stropheBorder)

            VStack(spacing: 16) {
                groupToolbarCard
                comparisonListCard
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()
                .background(Color.stropheBorder)

            // Bottom Actions
            HStack {
                Spacer()

                Button(String(localized: "cancel")) {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .tint(Color.stropheText)

                Button(String(localized: "done")) {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stropheAccent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 860, height: 680)
        .background(VisualEffectView(material: .sheet, blendingMode: .behindWindow))
    }
    #endif

    private var iOSContent: some View {
        NavigationStack {
            VStack(spacing: 16) {
                groupToolbarCard
                comparisonListCard
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .navigationTitle(String(localized: "bilingual_comparison_editor"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done")) { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.stropheAccent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var groupToolbarCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(macOS)
            HStack(spacing: 16) {
                primaryGroupPicker

                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(Color.stropheAccent)

                secondaryGroupPicker

                Spacer()

                TextField(String(localized: "search"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
            #else
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    primaryGroupPicker
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(Color.stropheAccent)
                    secondaryGroupPicker
                }

                TextField(String(localized: "search"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            #endif
        }
        .padding(14)
        .background(Color.stropheSecondaryBackground.opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.stropheBorder, lineWidth: 1)
        )
    }

    private var primaryGroupPicker: some View {
        Picker(String(localized: "primary_language_group"), selection: $primaryGroupID) {
            ForEach(store.sortedGroups) { group in
                Text(group.name).tag(Optional(group.id))
            }
        }
        .pickerStyle(.menu)
        #if os(macOS)
        .frame(maxWidth: 260)
        #else
        .frame(maxWidth: .infinity)
        #endif
    }

    private var secondaryGroupPicker: some View {
        Picker(String(localized: "secondary_language_group"), selection: $secondaryGroupID) {
            ForEach(store.sortedGroups) { group in
                Text(group.name).tag(Optional(group.id))
            }
        }
        .pickerStyle(.menu)
        #if os(macOS)
        .frame(maxWidth: 260)
        #else
        .frame(maxWidth: .infinity)
        #endif
    }

    private var comparisonListCard: some View {
        VStack(spacing: 0) {
            columnHeaders
            Divider()
                .background(Color.stropheBorder)
            comparisonList
        }
        .background(Color.stropheSecondaryBackground.opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.stropheBorder, lineWidth: 1)
        )
    }

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Text(primaryGroupName)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.stropheBlue)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(Color.stropheBorder)
                .frame(width: 1, height: 16)

            Text(secondaryGroupName)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.stropheAccent)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }

    private var comparisonList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sourceItems) { source in
                        BilingualCueEditorRow(
                            project: project,
                            source: source,
                            target: targetItem(for: source),
                            targetGroupID: secondaryGroupID
                        )
                        .id(source.id)
                        Divider()
                    }
                }
            }
            .stropheOnChange(of: project.scrollTargetID) { id in
                if let id {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func targetItem(for source: SubtitleItem) -> SubtitleItem? {
        guard let secondaryGroupID else { return nil }
        return project.items.first {
            ($0.parentItemID == source.id
                || (source.bilingualPairID != nil && $0.bilingualPairID == source.bilingualPairID))
                && project.belongsToGroup($0, groupID: secondaryGroupID, store: store)
        }
    }

    private var primaryGroupName: String {
        store.group(id: primaryGroupID)?.name ?? String(localized: "primary_language")
    }

    private var secondaryGroupName: String {
        store.group(id: secondaryGroupID)?.name ?? String(localized: "secondary_language")
    }
}

private struct BilingualCueEditorRow: View {
    @ObservedObject var project: SubtitleProject
    let source: SubtitleItem
    let target: SubtitleItem?
    let targetGroupID: UUID?

    @State private var sourceText: String
    @State private var targetText: String
    @FocusState private var focusedColumn: Column?

    private enum Column: Hashable {
        case source
        case target
    }

    init(
        project: SubtitleProject,
        source: SubtitleItem,
        target: SubtitleItem?,
        targetGroupID: UUID?
    ) {
        self.project = project
        self.source = source
        self.target = target
        self.targetGroupID = targetGroupID
        _sourceText = State(initialValue: source.text)
        _targetText = State(initialValue: target?.text ?? "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cueEditor(text: $sourceText, column: .source, isPlaceholder: false)
            Divider()
            cueEditor(
                text: $targetText,
                column: .target,
                isPlaceholder: target == nil && targetText.isEmpty
            )
        }
        .background(source.id == project.scrollTargetID ? Color.stropheAccent.opacity(0.08) : .clear)
        .overlay(alignment: .topLeading) {
            Button {
                if let start = source.startTime {
                    project.seek(to: start)
                    project.scrollTargetID = source.id
                }
            } label: {
                Text(source.startTime.map(shortTime) ?? "—")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.stropheBlue)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.stropheBlue.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(7)
        }
        .stropheOnChange(of: focusedColumn) { newValue in
            if newValue != .source {
                commitSource()
            }
            if newValue != .target {
                commitTarget()
            }
        }
        .stropheOnChange(of: source.text) { value in
            if focusedColumn != .source { sourceText = value }
        }
        .stropheOnChange(of: target?.text) { value in
            if focusedColumn != .target { targetText = value ?? "" }
        }
        .onDisappear {
            commitSource()
            commitTarget()
        }
    }

    private func cueEditor(
        text: Binding<String>,
        column: Column,
        isPlaceholder: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .focused($focusedColumn, equals: column)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.top, 20)
                .padding(.horizontal, 10)
                .frame(minHeight: 92)

            if isPlaceholder {
                Text(String(localized: "enter_translation"))
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 32)
                    .padding(.leading, 15)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func commitSource() {
        guard sourceText != source.text else { return }
        project.updateSubtitleText(id: source.id, text: sourceText)
    }

    private func commitTarget() {
        guard let targetGroupID else { return }
        if let target {
            guard targetText != target.text else { return }
            project.updateSubtitleText(id: target.id, text: targetText)
        } else if !targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            project.upsertTranslation(
                sourceID: source.id,
                targetGroupID: targetGroupID,
                text: targetText,
                languageCode: nil
            )
        }
    }

    private func shortTime(_ value: Double) -> String {
        let total = max(0, Int(value))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
