import SwiftUI

struct PinyinConversionSheet: View {
    @ObservedObject var project: SubtitleProject
    @Environment(\.dismiss) private var dismiss

    private var selectedCount: Int {
        project.items.filter { project.selectedIDs.contains($0.id) }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "character.phonetic")
                    .font(.system(size: 38))
                    .foregroundStyle(Color.stropheAccent)
                Text("chinese_to_pinyin")
                    .font(.title2.bold())
                Text(selectedCount == 0
                     ? "select_subtitle_blocks_first_hint"
                     : "convert_selected_pinyin_explanation_format \(selectedCount)")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                Spacer(minLength: 0)
            }
            .padding(28)
            .navigationTitle("language_processing")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("apply") {
                        project.convertSelectedSubtitlesToPinyin()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedCount == 0)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 300)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([.medium])
        #endif
    }
}

struct AutoLineWrapSheet: View {
    @ObservedObject var project: SubtitleProject
    @Environment(\.dismiss) private var dismiss

    @State private var languageMode: AutoWrapLanguageMode = .words
    @State private var outputMode: AutoWrapOutputMode = .insertLineBreaks
    @State private var maximumLength = 32

    private var selectedItems: [SubtitleItem] {
        project.items.filter { project.selectedIDs.contains($0.id) }
    }

    private var averageLength: Int {
        guard !selectedItems.isEmpty else { return 0 }
        return selectedItems.reduce(0) { $0 + $1.text.count } / selectedItems.count
    }

    private var maximumSourceLength: Int {
        selectedItems.map { $0.text.count }.max() ?? 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("batch_operation_summary_format \(selectedItems.count) \(averageLength) \(maximumSourceLength)")
                        .foregroundStyle(.secondary)
                }
                Section("language_type") {
                    Picker("language_type", selection: $languageMode) {
                        ForEach(AutoWrapLanguageMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    Text(languageMode == .words
                         ? "process_by_spaces_explanation"
                         : "process_by_char_length_explanation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("line_break_method") {
                    Picker("line_break_method", selection: $outputMode) {
                        ForEach(AutoWrapOutputMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("single_line_char_limit") {
                    Stepper(value: $maximumLength, in: 4...120) {
                        LabeledContent("max_length", value: "\(maximumLength)")
                    }
                    Slider(value: Binding(
                        get: { Double(maximumLength) },
                        set: { maximumLength = Int($0.rounded()) }
                    ), in: 4...120, step: 1)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("auto_line_wrap")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("apply") {
                        project.autoWrapSelectedSubtitles(
                            maximumLength: maximumLength,
                            languageMode: languageMode,
                            outputMode: outputMode
                        )
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedItems.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 470)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([.medium, .large])
        #endif
    }
}
