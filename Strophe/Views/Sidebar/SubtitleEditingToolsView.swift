//
//  SubtitleEditingToolsView.swift
//  Strophe
//

import SwiftUI

struct SubtitleEditingToolsView: View {
    @ObservedObject var project: SubtitleProject
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var replacement = ""
    @State private var options = SubtitleSearchOptions()
    @State private var filter: SubtitleFilter = .all
    @State private var shiftSeconds = 0.5
    @State private var stretchFactor = 1.0
    @State private var normalizedGap = 0.08
    @State private var overlapGap = 0.04
    @State private var overlapMode: SubtitleOverlapRepairMode = .trimEarlier
    @State private var replacementSummary = ""

    private var matchingItems: [SubtitleItem] {
        project.filteredSubtitleItems(
            query: query,
            options: options,
            filter: filter
        )
    }

    private var operationIDs: Set<UUID> {
        project.selectedIDs.isEmpty
            ? Set(matchingItems.map(\.id))
            : project.selectedIDs
    }

    private var statistics: SubtitleStatistics {
        project.subtitleStatistics(for: Set(matchingItems.map(\.id)))
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
                Text("subtitle_editing_tools")
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

            ScrollView {
                VStack(spacing: 20) {
                    searchCard
                    statisticsCard
                    batchTimingCard
                    resultsCard
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }

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
        .frame(width: 560, height: 720)
        .background(VisualEffectView(material: .sheet, blendingMode: .behindWindow))
        .accessibilityIdentifier("subtitleEditingTools")
    }
    #endif

    private var iOSContent: some View {
        NavigationStack {
            Form {
                searchSection
                statisticsSection
                batchTimingSection
                resultsSection
            }
            .accessibilityIdentifier("subtitleEditingTools")
            .formStyle(.grouped)
            .navigationTitle(String(localized: "subtitle_editing_tools"))
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

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("search_replace_filter")
                .font(.headline)
                .foregroundStyle(Color.stropheText)

            VStack(spacing: 10) {
                TextField(String(localized: "search"), text: $query)
                    .textFieldStyle(.roundedBorder)

                TextField(String(localized: "replace_with"), text: $replacement)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text(String(localized: "filter"))
                        .font(.subheadline)
                    Spacer()
                    Picker("", selection: $filter) {
                        ForEach(SubtitleFilter.allCases) { value in
                            Text(title(for: value)).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            Divider()
                .background(Color.stropheBorder)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(String(localized: "case_sensitive"), isOn: $options.isCaseSensitive)
                    .tint(Color.stropheAccent)
                Toggle(String(localized: "regular_expression"), isOn: $options.usesRegularExpression)
                    .tint(Color.stropheAccent)
                Toggle(String(localized: "whole_words"), isOn: $options.matchesWholeWords)
                    .tint(Color.stropheAccent)
            }

            Divider()
                .background(Color.stropheBorder)

            HStack(spacing: 12) {
                Button(String(localized: "select_results")) {
                    project.selectedIDs = Set(matchingItems.map(\.id))
                }
                .buttonStyle(.bordered)
                .tint(Color.stropheBlue)
                .disabled(matchingItems.isEmpty)

                Button(String(localized: "replace_all")) {
                    let count = project.replaceSubtitleText(
                        query: query,
                        replacement: replacement,
                        options: options,
                        ids: Set(matchingItems.map(\.id))
                    )
                    replacementSummary = String.localizedStringWithFormat(
                        String(localized: "replacement_summary_format"),
                        count
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stropheAccent)
                .disabled(query.isEmpty || matchingItems.isEmpty)
            }

            if !replacementSummary.isEmpty {
                Text(replacementSummary)
                    .font(.caption)
                    .foregroundStyle(Color.stropheAccent)
            }
        }
        .padding(16)
        .background(Color.stropheSecondaryBackground.opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.stropheBorder, lineWidth: 1)
        )
    }

    private var statisticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("statistics")
                .font(.headline)
                .foregroundStyle(Color.stropheText)

            VStack(spacing: 8) {
                LabeledContent(String(localized: "subtitle_count"), value: "\(statistics.totalCount)")
                LabeledContent(
                    String(localized: "timed_untimed"),
                    value: "\(statistics.timedCount) / \(statistics.untimedCount)"
                )
                LabeledContent(
                    String(localized: "characters_words"),
                    value: "\(statistics.characterCount) / \(statistics.wordCount)"
                )
                LabeledContent(
                    String(localized: "average_cue_duration"),
                    value: statistics.averageCueDuration.formatted(.number.precision(.fractionLength(2))) + " s"
                )
                LabeledContent(
                    String(localized: "average_max_cps"),
                    value: statistics.averageCharactersPerSecond.formatted(.number.precision(.fractionLength(1)))
                        + " / "
                        + statistics.maximumCharactersPerSecond.formatted(.number.precision(.fractionLength(1)))
                )
                LabeledContent(
                    String(localized: "gaps_overlaps"),
                    value: "\(statistics.gapCount) / \(statistics.overlapCount)"
                )
            }
        }
        .padding(16)
        .background(Color.stropheSecondaryBackground.opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.stropheBorder, lineWidth: 1)
        )
    }

    private var batchTimingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("batch_timing")
                .font(.headline)
                .foregroundStyle(Color.stropheText)

            VStack(spacing: 10) {
                HStack {
                    Text(String(localized: "shift_seconds"))
                        .font(.subheadline)
                    Spacer()
                    TextField("", value: $shiftSeconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Button(String(localized: "apply_shift")) {
                        project.shiftSubtitles(ids: operationIDs, by: shiftSeconds)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.stropheAccent)
                    .disabled(operationIDs.isEmpty)
                }

                HStack {
                    Text(String(localized: "stretch_factor"))
                        .font(.subheadline)
                    Spacer()
                    TextField("", value: $stretchFactor, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Button(String(localized: "apply_stretch")) {
                        project.stretchSubtitles(ids: operationIDs, factor: stretchFactor)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.stropheAccent)
                    .disabled(operationIDs.isEmpty || stretchFactor <= 0)
                }

                HStack {
                    Text(String(localized: "target_gap_seconds"))
                        .font(.subheadline)
                    Spacer()
                    TextField("", value: $normalizedGap, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Button(String(localized: "normalize_gaps")) {
                        project.normalizeSubtitleGaps(ids: operationIDs, gap: normalizedGap)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.stropheAccent)
                    .disabled(operationIDs.count < 2)
                }

                Divider()
                    .background(Color.stropheBorder)

                HStack {
                    Picker(String(localized: "overlap_repair_mode"), selection: $overlapMode) {
                        Text("trim_earlier").tag(SubtitleOverlapRepairMode.trimEarlier)
                        Text("shift_later").tag(SubtitleOverlapRepairMode.shiftLater)
                    }
                    .pickerStyle(.menu)

                    Spacer()

                    TextField("", value: $overlapGap, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)

                    Button(String(localized: "repair_overlaps")) {
                        project.repairSubtitleOverlaps(
                            ids: operationIDs,
                            minimumGap: max(0, overlapGap),
                            mode: overlapMode
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.stropheAccent)
                    .disabled(operationIDs.count < 2)
                }
            }
        }
        .padding(16)
        .background(Color.stropheSecondaryBackground.opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.stropheBorder, lineWidth: 1)
        )
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String.localizedStringWithFormat(
                String(localized: "results_count_format"),
                matchingItems.count
            ))
            .font(.headline)
            .foregroundStyle(Color.stropheText)

            Divider()
                .background(Color.stropheBorder)

            if matchingItems.isEmpty {
                Text("no_matching_subtitles")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(matchingItems.prefix(100)) { item in
                        Button {
                            project.selectedIDs = [item.id]
                            project.scrollTargetID = item.id
                            if let start = item.startTime {
                                project.seek(to: start)
                            }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(item.startTime.map(shortTime) ?? "—")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Color.stropheBlue)
                                Text(item.text.replacingOccurrences(of: "\n", with: " "))
                                    .lineLimit(2)
                                    .foregroundStyle(Color.stropheText)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.stropheSecondaryBackground.opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.stropheBorder, lineWidth: 1)
        )
    }

    private var searchSection: some View {
        Section {
            TextField(String(localized: "search"), text: $query)
            TextField(String(localized: "replace_with"), text: $replacement)

            Picker(String(localized: "filter"), selection: $filter) {
                ForEach(SubtitleFilter.allCases) { value in
                    Text(title(for: value)).tag(value)
                }
            }

            Toggle(String(localized: "case_sensitive"), isOn: $options.isCaseSensitive)
            Toggle(String(localized: "regular_expression"), isOn: $options.usesRegularExpression)
            Toggle(String(localized: "whole_words"), isOn: $options.matchesWholeWords)

            HStack {
                Button(String(localized: "select_results")) {
                    project.selectedIDs = Set(matchingItems.map(\.id))
                }
                .disabled(matchingItems.isEmpty)

                Button(String(localized: "replace_all")) {
                    let count = project.replaceSubtitleText(
                        query: query,
                        replacement: replacement,
                        options: options,
                        ids: Set(matchingItems.map(\.id))
                    )
                    replacementSummary = String.localizedStringWithFormat(
                        String(localized: "replacement_summary_format"),
                        count
                    )
                }
                .disabled(query.isEmpty || matchingItems.isEmpty)
            }

            if !replacementSummary.isEmpty {
                Text(replacementSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("search_replace_filter")
        } footer: {
            Text(project.selectedIDs.isEmpty
                 ? String(localized: "batch_scope_filtered_results")
                 : String.localizedStringWithFormat(
                    String(localized: "batch_scope_selection_format"),
                    project.selectedIDs.count
                 ))
        }
    }

    private var statisticsSection: some View {
        Section("statistics") {
            LabeledContent(String(localized: "subtitle_count"), value: "\(statistics.totalCount)")
            LabeledContent(
                String(localized: "timed_untimed"),
                value: "\(statistics.timedCount) / \(statistics.untimedCount)"
            )
            LabeledContent(
                String(localized: "characters_words"),
                value: "\(statistics.characterCount) / \(statistics.wordCount)"
            )
            LabeledContent(
                String(localized: "average_cue_duration"),
                value: statistics.averageCueDuration.formatted(.number.precision(.fractionLength(2))) + " s"
            )
            LabeledContent(
                String(localized: "average_max_cps"),
                value: statistics.averageCharactersPerSecond.formatted(.number.precision(.fractionLength(1)))
                    + " / "
                    + statistics.maximumCharactersPerSecond.formatted(.number.precision(.fractionLength(1)))
            )
            LabeledContent(
                String(localized: "gaps_overlaps"),
                value: "\(statistics.gapCount) / \(statistics.overlapCount)"
            )
        }
    }

    private var batchTimingSection: some View {
        Section("batch_timing") {
            LabeledContent(String(localized: "shift_seconds")) {
                TextField("", value: $shiftSeconds, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
            Button(String(localized: "apply_shift")) {
                project.shiftSubtitles(ids: operationIDs, by: shiftSeconds)
            }
            .disabled(operationIDs.isEmpty)

            LabeledContent(String(localized: "stretch_factor")) {
                TextField("", value: $stretchFactor, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
            Button(String(localized: "apply_stretch")) {
                project.stretchSubtitles(ids: operationIDs, factor: stretchFactor)
            }
            .disabled(operationIDs.isEmpty || stretchFactor <= 0)

            LabeledContent(String(localized: "target_gap_seconds")) {
                TextField("", value: $normalizedGap, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
            Button(String(localized: "normalize_gaps")) {
                project.normalizeSubtitleGaps(ids: operationIDs, gap: normalizedGap)
            }
            .disabled(operationIDs.count < 2)

            Picker(String(localized: "overlap_repair_mode"), selection: $overlapMode) {
                Text("trim_earlier").tag(SubtitleOverlapRepairMode.trimEarlier)
                Text("shift_later").tag(SubtitleOverlapRepairMode.shiftLater)
            }
            LabeledContent(String(localized: "minimum_gap_seconds")) {
                TextField("", value: $overlapGap, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
            Button(String(localized: "repair_overlaps")) {
                project.repairSubtitleOverlaps(
                    ids: operationIDs,
                    minimumGap: max(0, overlapGap),
                    mode: overlapMode
                )
            }
            .disabled(operationIDs.count < 2)
        }
    }

    private var resultsSection: some View {
        Section {
            if matchingItems.isEmpty {
                Text("no_matching_subtitles")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matchingItems.prefix(100)) { item in
                    Button {
                        project.selectedIDs = [item.id]
                        project.scrollTargetID = item.id
                        if let start = item.startTime {
                            project.seek(to: start)
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(item.startTime.map(shortTime) ?? "—")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(item.text.replacingOccurrences(of: "\n", with: " "))
                                .lineLimit(2)
                                .foregroundStyle(Color.stropheText)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text(String.localizedStringWithFormat(
                String(localized: "results_count_format"),
                matchingItems.count
            ))
        } footer: {
            if matchingItems.count > 100 {
                Text("showing_first_100_results")
            }
        }
    }

    private func title(for filter: SubtitleFilter) -> String {
        String(localized: String.LocalizationValue("subtitle_filter_\(filter.rawValue)"))
    }

    private func shortTime(_ value: Double) -> String {
        let total = max(0, Int(value))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
