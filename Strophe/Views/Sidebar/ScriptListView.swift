import SwiftUI
import UniformTypeIdentifiers

struct ScriptListView: View {
    @ObservedObject var project: SubtitleProject
    @State private var scriptText: String = ""
    @State private var isShowingInput = false
    @State private var isShowingFileImporter = false
    @State private var isShowingImportOptions = false
    
    // 文字编辑控制
    @State private var isEditingText = false
    @State private var editingText = ""
    @State private var editingItem: SubtitleItem? = nil
    @State private var isEditingTime = false
    @State private var editingStartText = ""
    @State private var editingEndText = ""
    @State private var editingTimeItem: SubtitleItem? = nil
    @State private var isShowingAutoCaption = false
    @ObservedObject private var store = StyleAndGroupStore.shared
    
    /// Legacy compact-mode support (iOS 17 / macOS 14 fallback).
    /// When using the modern TabView path these default values are used.
    var isCompact: Bool = false
    var path: Binding<NavigationPath> = .constant(NavigationPath())

    var body: some View {
        Group {
            if project.items.isEmpty {
                emptyState
            } else {
                scriptList
            }
        }
        .opacity(project.editingMode == .creation ? 0.95 : 1.0)
        .sheet(isPresented: $isShowingInput) {
            ScriptImportSheet(scriptText: $scriptText, isPresented: $isShowingInput) {
                project.importScript(scriptText)
                scriptText = ""
            }
        }
        .onChange(of: isShowingInput) { newValue in
            project.isEditingText = newValue
        }
        .sheet(isPresented: $isEditingText) {
            SubtitleTextEditSheet(
                title: String(localized: "编辑字幕内容"),
                text: $editingText,
                isPresented: $isEditingText
            ) {
                if let item = editingItem {
                    project.updateSubtitleText(id: item.id, text: editingText)
                }
                editingItem = nil
            }
        }
        .onChange(of: isEditingText) { newValue in
            if !newValue {
                editingItem = nil
            }
            project.isEditingText = newValue
        }
        .alert(String(localized: "更改显示时间"), isPresented: $isEditingTime) {
            TextField("起始时间，例如 01:23.45", text: $editingStartText)
            TextField("结束时间，例如 01:25.20", text: $editingEndText)
            Button("确定") {
                saveEditingTime()
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                editingTimeItem = nil
            }
        } message: {
            Text("可输入秒数、MM:SS 或 HH:MM:SS")
        }
        .onChange(of: isEditingTime) { newValue in
            project.isEditingText = newValue
        }
        .confirmationDialog(String(localized: "Import Script"), isPresented: $isShowingImportOptions, titleVisibility: .visible) {
            Button(String(localized: "Paste Script Text")) {
                isShowingInput = true
            }
            Button(String(localized: "Import File…")) {
                isShowingFileImporter = true
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: UTType.allSubtitleTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let rawText = try SubtitleEngine.loadRawText(from: url)
                    project.importScript(rawText)
                } catch {
                    print("Failed to read script file: \(error.localizedDescription)")
                }
            case .failure(let error):
                print("File import failed: \(error.localizedDescription)")
            }
        }
        .onChange(of: isShowingFileImporter) { newValue in
            project.isEditingText = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .strophePasteScript)) { _ in
            isShowingInput = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheImportScriptFile)) { _ in
            isShowingFileImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheStartSpeechRecognition)) { _ in
            isShowingAutoCaption = true
        }
        .sheet(isPresented: $isShowingAutoCaption) {
            AutoCaptionView(project: project)
        }
        .onChange(of: isShowingAutoCaption) { newValue in
            project.isEditingText = newValue
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("No Script")
                .font(.headline)
            Text("Paste your script to start marking timestamps.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                Button("Import Script…") {
                    isShowingImportOptions = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stropheAccent)
                
                #if !STROPHE_LITE
                Button("Speech Recognition…") {
                    isShowingAutoCaption = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stropheAccent)
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Script List
    private var scriptList: some View {
        ScrollViewReader { scrollProxy in
            List(selection: $project.selectedIDs) {
                ForEach(project.items) { item in
                    let group = project.subgroup(for: item, store: store)
                    let isLocked = item.isLocked || group?.isLocked == true

                    SubtitleRow(
                        item: item,
                        isActive: item.id == project.scrollTargetID,
                        isOverlapping: project.isItemOverlapping(id: item.id),
                        group: group
                    )
                    .equatable()
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowSeparator(.hidden)
                    .id(item.id)
                    .tag(item.id)
                    .onTapGestureIf(condition: project.isSubtitleMultiSelecting) {
                        if project.selectedIDs.contains(item.id) {
                            project.selectedIDs.remove(item.id)
                            if project.selectedIDs.isEmpty {
                                project.isSubtitleMultiSelecting = false
                            }
                        } else {
                            project.selectedIDs.insert(item.id)
                        }
                    }
                    .contextMenu {
                        Button(action: {
                            project.isSubtitleMultiSelecting = true
                            if !project.selectedIDs.contains(item.id) {
                                project.selectedIDs.insert(item.id)
                            }
                        }) {
                            Label("多选字幕块", systemImage: "checklist")
                        }

                        Button(action: {
                            editingItem = item
                            editingText = project.items.first(where: { $0.id == item.id })?.text ?? item.text
                            isEditingText = true
                        }) {
                            Label("编辑内容", systemImage: "pencil")
                        }
                        .disabled(isLocked)

                        Button(action: {
                            beginEditingTime(item)
                        }) {
                            Label("更改显示时间", systemImage: "clock")
                        }
                        .disabled(isLocked)

                        Menu {
                            ForEach(store.sortedGroups) { grp in
                                Button(action: {
                                    if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                                        project.assignSelectedSubtitles(toGroup: grp.id)
                                    } else {
                                        project.assignSubtitle(id: item.id, toGroup: grp.id)
                                    }
                                }) {
                                    HStack {
                                        if item.groupID == grp.id {
                                            Image(systemName: "checkmark")
                                        }
                                        Text(grp.name)
                                    }
                                }
                            }
                        } label: {
                            Label("移动到分组", systemImage: "square.stack.3d.up")
                        }
                        .disabled(isLocked)

                        Menu {
                            Button(action: {
                                if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                                    project.setSelectedSubtitleStyleOverride(styleID: nil)
                                } else {
                                    project.followGroupStyle(id: item.id)
                                }
                            }) {
                                HStack {
                                    if !item.hasIndependentPresentation {
                                        Image(systemName: "checkmark")
                                    }
                                    Text("跟随小组样式")
                                }
                            }

                            if !store.styles.isEmpty {
                                Divider()
                            }

                            ForEach(store.styles) { style in
                                Button(action: {
                                    if project.selectedIDs.count > 1, project.selectedIDs.contains(item.id) {
                                        project.setSelectedSubtitleStyleOverride(styleID: style.id)
                                    } else {
                                        project.setSubtitleStyleOverride(id: item.id, styleID: style.id)
                                    }
                                }) {
                                    HStack {
                                        if item.styleID == style.id {
                                            Image(systemName: "checkmark")
                                        }
                                        Text(style.name)
                                    }
                                }
                            }
                        } label: {
                            Label("设定样式", systemImage: "textformat")
                        }
                        .disabled(isLocked)

                        Divider()

                        Button(role: .destructive, action: {
                            project.deleteSubtitle(id: item.id)
                        }) {
                            Label("删除字幕", systemImage: "trash")
                        }
                        .disabled(isLocked)
                    }
                    .disabled(project.editingMode == .creation)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .venturaFixedListRowHeight(70)
            .onDeleteCommandIfSupported {
                if !project.selectedIDs.isEmpty {
                    project.deleteSubtitles(ids: project.selectedIDs)
                    project.selectedIDs.removeAll()
                }
            }
            .onChange(of: project.scrollTargetID) { newID in
                if let newID = newID {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        scrollProxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
            .onAppear {
                if let activeID = project.scrollTargetID {
                    scrollProxy.scrollTo(activeID, anchor: .center)
                }
            }
        }
    }

    private func beginEditingTime(_ item: SubtitleItem) {
        editingTimeItem = item
        editingStartText = formatEditableTime(item.startTime ?? 0)
        editingEndText = formatEditableTime(item.endTime ?? ((item.startTime ?? 0) + 2))
        isEditingTime = true
    }

    private func saveEditingTime() {
        guard let item = editingTimeItem,
              let newStart = parseEditableTime(editingStartText),
              let newEnd = parseEditableTime(editingEndText) else { return }
        project.updateSubtitleTime(id: item.id, newStartTime: newStart, newEndTime: newEnd)
        editingTimeItem = nil
    }

    private func formatEditableTime(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let totalSeconds = Int(clamped)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        let cs = Int(((clamped - Double(totalSeconds)) * 100).rounded())
        return h > 0
            ? String(format: "%d:%02d:%02d.%02d", h, m, s, cs)
            : String(format: "%02d:%02d.%02d", m, s, cs)
    }

    private func parseEditableTime(_ raw: String) -> TimeInterval? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty else { return nil }
        let parts = normalized.split(separator: ":").map(String.init)
        if parts.count == 1 {
            return Double(parts[0]).map { max(0, $0) }
        }

        var total = 0.0
        for (index, part) in parts.reversed().enumerated() {
            guard let value = Double(part) else { return nil }
            total += value * pow(60.0, Double(index))
        }
        return max(0, total)
    }
}

// MARK: - View Extension for Multiplatform Support
extension View {
    @ViewBuilder
    func onDeleteCommandIfSupported(perform action: (() -> Void)?) -> some View {
        #if os(macOS)
        if let action = action {
            self.onDeleteCommand(perform: action)
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func onTapGestureIf(condition: Bool, action: @escaping () -> Void) -> some View {
        if condition {
            self.onTapGesture(perform: action)
        } else {
            self
        }
    }
}
