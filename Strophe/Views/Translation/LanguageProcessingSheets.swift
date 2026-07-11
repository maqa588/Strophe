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
                Text("汉字转拼音")
                    .font(.title2.bold())
                Text(selectedCount == 0
                     ? "请先在文稿或时间轴中选择要转换的字幕块。"
                     : "将转换所选的 \(selectedCount) 个字幕块。拼音保留声调，非汉字内容保持不变。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                Spacer(minLength: 0)
            }
            .padding(28)
            .navigationTitle("语言处理")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
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
                    Text("操作 \(selectedItems.count) 个对象（平均 \(averageLength) 字符，最大 \(maximumSourceLength) 字符）")
                        .foregroundStyle(.secondary)
                }
                Section("语言类型") {
                    Picker("语言类型", selection: $languageMode) {
                        ForEach(AutoWrapLanguageMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    Text(languageMode == .words
                         ? "按空格识别单词，换行时不会切断单词。"
                         : "按字符长度处理，适合中文、日文等连续型文本。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("换行方式") {
                    Picker("换行方式", selection: $outputMode) {
                        ForEach(AutoWrapOutputMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("单行字符长度") {
                    Stepper(value: $maximumLength, in: 4...120) {
                        LabeledContent("最大长度", value: "\(maximumLength)")
                    }
                    Slider(value: Binding(
                        get: { Double(maximumLength) },
                        set: { maximumLength = Int($0.rounded()) }
                    ), in: 4...120, step: 1)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("自动换行")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
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
