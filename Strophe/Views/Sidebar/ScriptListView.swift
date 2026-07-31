import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
    import AppKit
#endif

struct ScriptListView: View {
    @ObservedObject var project: SubtitleProject
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var scriptText: String = ""
    @State private var isShowingInput = false
    @State private var isShowingFileImporter = false
    @State private var isShowingImportOptions = false
    @State private var quickSearchText = ""

    @State private var isEditingText = false
    @State private var editingText = ""
    @State private var editingItem: SubtitleItem? = nil
    @State private var isEditingTime = false
    @State private var editingStartText = ""
    @State private var editingEndText = ""
    @State private var editingTimeItem: SubtitleItem? = nil
    @State private var isShowingAutoCaption = false
    @State private var isShowingTranslationAssistant = false
    @State private var translationStartItemID: UUID?
    @State private var isShowingBatchTranslation = false
    @State private var isShowingPinyinConversion = false
    @State private var isShowingAutoLineWrap = false
    @State private var isShowingKaraokeBatchRecognition = false
    @State private var isSearchRevealed = false
    @State private var isListAtTop = true
    @State private var subtitleListSearchOffset: CGFloat = 0
    @State private var searchFocusTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool
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
        .stropheOnChange(of: isShowingInput) { newValue in
            project.isEditingText = newValue
        }
        .sheet(isPresented: $isEditingText) {
            SubtitleTextEditSheet(
                title: String(localized: "edit_subtitle_content"),
                text: $editingText,
                isPresented: $isEditingText
            ) {
                if let item = editingItem {
                    project.updateSubtitleText(id: item.id, text: editingText)
                }
                editingItem = nil
            }
        }
        .stropheOnChange(of: isEditingText) { newValue in
            if !newValue {
                editingItem = nil
            }
            project.isEditingText = newValue
        }
        .alert(String(localized: "change_display_time"), isPresented: $isEditingTime) {
            TextField("start_time_eg_012345", text: $editingStartText)
            TextField("end_time_eg_012520", text: $editingEndText)
            Button("ok_1") {
                saveEditingTime()
            }
            Button(String(localized: "btn_cancel"), role: .cancel) {
                editingTimeItem = nil
            }
        } message: {
            Text("can_enter_seconds_mmss_or")
        }
        .stropheOnChange(of: isEditingTime) { newValue in
            project.isEditingText = newValue
        }
        .confirmationDialog(
            String(localized: "import_script"), isPresented: $isShowingImportOptions, titleVisibility: .visible
        ) {
            Button(String(localized: "paste_script_text")) {
                isShowingInput = true
            }
            Button(String(localized: "import_file")) {
                isShowingFileImporter = true
            }
            Button(String(localized: "btn_cancel"), role: .cancel) {}
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
                    try project.importSubtitle(from: url)
                } catch {
                    print("Failed to read script file: \(error.localizedDescription)")
                }
            case .failure(let error):
                print("File import failed: \(error.localizedDescription)")
            }
        }
        .stropheOnChange(of: isShowingFileImporter) { newValue in
            project.isEditingText = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .strophePasteScript)) { _ in
            isShowingInput = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheStartSpeechRecognition)) { _ in
            isShowingAutoCaption = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheStartSubtitleTranslation)) { notification in
            translationStartItemID = notification.object as? UUID
            isShowingTranslationAssistant = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheStartBatchTranslation)) { _ in
            isShowingBatchTranslation = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheConvertSelectedToPinyin)) { _ in
            isShowingPinyinConversion = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheOpenAutoLineWrap)) { _ in
            isShowingAutoLineWrap = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .stropheOpenKaraokeBatchRecognition)) { _ in
            isShowingKaraokeBatchRecognition = true
        }
        .sheet(isPresented: $isShowingAutoCaption) {
            AutoCaptionView(project: project)
        }
        .stropheOnChange(of: isShowingAutoCaption) { newValue in
            project.isEditingText = newValue
        }
        .sheet(isPresented: $isShowingTranslationAssistant) {
            SubtitleTranslationAssistantView(project: project, startItemID: translationStartItemID)
        }
        .sheet(isPresented: $isShowingBatchTranslation) {
            BatchTranslationView(project: project)
        }
        .sheet(isPresented: $isShowingPinyinConversion) {
            PinyinConversionSheet(project: project)
        }
        .sheet(isPresented: $isShowingAutoLineWrap) {
            AutoLineWrapSheet(project: project)
        }
        .sheet(isPresented: $isShowingKaraokeBatchRecognition) {
            KaraokeBatchRecognitionSheet(project: project)
        }
        .stropheOnChange(of: isShowingTranslationAssistant) { newValue in
            project.isEditingText = newValue
            if !newValue { translationStartItemID = nil }
        }
        .stropheOnChange(of: isShowingBatchTranslation) { project.isEditingText = $0 }
        .stropheOnChange(of: isShowingPinyinConversion) { project.isEditingText = $0 }
        .stropheOnChange(of: isShowingAutoLineWrap) { project.isEditingText = $0 }
        .stropheOnChange(of: isShowingKaraokeBatchRecognition) { project.isEditingText = $0 }
        .stropheOnChange(of: store.activeGroupID) { _ in
            project.autoUpdateCurrentIndex()
        }
        .onDisappear {
            searchFocusTask?.cancel()
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("no_script")
                .font(.headline)
            Text("paste_script_to_start")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                Button("import_script_ellipsis") {
                    isShowingImportOptions = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stropheAccent)

                Button("speech_recognition_1") {
                    isShowingAutoCaption = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stropheAccent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Script List
    private var scriptList: some View {
        let visibleItems = filteredItems

        return ScrollViewReader { scrollProxy in
            ZStack(alignment: .top) {
                List(selection: $project.selectedIDs) {
                    ForEach(visibleItems) { item in
                        let group = project.subgroup(for: item, store: store)
                        let isLocked = item.isLocked || group?.isLocked == true

                        SubtitleRow(
                            project: project,
                            item: item,
                            isActive: item.id == project.scrollTargetID,
                            isOverlapping: project.isItemOverlapping(id: item.id),
                            group: group,
                            isSlapping: item.id == project.activeSlapSubtitleID
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
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                if let group {
                                    StyleAndGroupStore.shared.setActiveGroup(group.id)
                                }
                                if !isLocked {
                                    editingItem = item
                                    editingText = project.items.first(where: { $0.id == item.id })?.text ?? item.text
                                    isEditingText = true
                                }
                            }
                        )
                        .contextMenu {
                            Button(action: {
                                project.isSubtitleMultiSelecting = true
                                if !project.selectedIDs.contains(item.id) {
                                    project.selectedIDs.insert(item.id)
                                }
                            }) {
                                Label("multi_select_subtitle_blocks", systemImage: "checklist")
                            }

                            Button(action: {
                                editingItem = item
                                editingText =
                                    project.items.first(where: { $0.id == item.id })?.text
                                    ?? item.text
                                isEditingText = true
                            }) {
                                Label("edit_content", systemImage: "pencil")
                            }
                            .disabled(isLocked)

                            Button(action: {
                                beginEditingTime(item)
                            }) {
                                Label("change_display_time", systemImage: "clock")
                            }
                            .disabled(isLocked)

                            Toggle(
                                isOn: karaokeBlockActionBinding(for: item)
                            ) {
                                Label(
                                    "karaoke",
                                    systemImage: "music.note.list"
                                )
                            }
                            .disabled(
                                !project.canSetKaraokeFromBlockAction(
                                    itemID: item.id
                                )
                            )

                            Menu {
                                ForEach(store.sortedGroups) { grp in
                                    Button(action: {
                                        if project.selectedIDs.count > 1,
                                            project.selectedIDs.contains(item.id)
                                        {
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
                                Label("move_to_group", systemImage: "square.stack.3d.up")
                            }
                            .disabled(isLocked)

                            Menu {
                                Button(action: {
                                    if project.selectedIDs.count > 1,
                                        project.selectedIDs.contains(item.id)
                                    {
                                        project.setSelectedSubtitleStyleOverride(styleID: nil)
                                    } else {
                                        project.followGroupStyle(id: item.id)
                                    }
                                }) {
                                    HStack {
                                        if !item.hasIndependentPresentation {
                                            Image(systemName: "checkmark")
                                        }
                                        Text("follow_group_style")
                                    }
                                }

                                if !store.styles.isEmpty {
                                    Divider()
                                }

                                ForEach(store.styles) { style in
                                    Button(action: {
                                        if project.selectedIDs.count > 1,
                                            project.selectedIDs.contains(item.id)
                                        {
                                            project.setSelectedSubtitleStyleOverride(
                                                styleID: style.id)
                                        } else {
                                            project.setSubtitleStyleOverride(
                                                id: item.id, styleID: style.id)
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
                                Label("set_style", systemImage: "textformat")
                            }
                            .disabled(isLocked)

                            Button {
                                NotificationCenter.default.post(
                                    name: .stropheStartSubtitleTranslation, object: item.id)
                            } label: {
                                Label(
                                    "start_translation_from_here", systemImage: "character.bubble")
                            }

                            Divider()

                            Button(
                                role: .destructive,
                                action: {
                                    project.deleteSubtitle(id: item.id)
                                }
                            ) {
                                Label("delete_subtitle", systemImage: "trash")
                            }
                            .disabled(isLocked)
                        }
                        .disabled(project.editingMode == .creation)
                    }
                }
                .listStyle(.sidebar)
                .offset(y: subtitleListSearchOffset)
                .strophePullToSearch(isAtTop: $isListAtTop) {
                    revealSearch()
                } onScrollUp: {
                    if isSearchRevealed && quickSearchText.isEmpty {
                        dismissSearch()
                    }
                } onScrollEnd: {
                    settleSubtitleListBelowSearch()
                    scheduleSearchFocus()
                } onPullProgress: { progress in
                    #if os(macOS)
                        updateMacSubtitlePullProgress(progress)
                    #endif
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .venturaFixedListRowHeight(70)
                .onDeleteCommandIfSupported {
                    if !project.selectedIDs.isEmpty {
                        project.deleteSubtitles(ids: project.selectedIDs)
                        project.selectedIDs.removeAll()
                    }
                }
                .stropheOnChange(of: project.scrollTargetID) { newID in
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

                if isSearchRevealed || !quickSearchText.isEmpty {
                    subtitleSearchField
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .transition(searchTransition)
                        .zIndex(1)
                }
            }
        }
    }

    private var filteredItems: [SubtitleItem] {
        project.items.filter { item in
            let isInActiveGroup =
                store.activeGroupID.map {
                    project.belongsToGroup(item, groupID: $0, store: store)
                } ?? true
            return isInActiveGroup
                && SubtitleEditingTools.matches(
                    item.text,
                    query: quickSearchText,
                    options: SubtitleSearchOptions()
                )
        }
    }

    private var subtitleSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.medium))
                .foregroundStyle(isSearchFocused ? Color.stropheAccent : Color.secondary)
                .accessibilityHidden(true)

            TextField(String(localized: "search_subtitles"), text: $quickSearchText)
                .font(.body)
                .textFieldStyle(.plain)
                .stropheStableSearchTextFieldLayout()
                .focused($isSearchFocused)
                .autocorrectionDisabled()

            Button(action: dismissSearch) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("close"))
            .help(String(localized: "close"))
        }
        .padding(.leading, 14)
        .frame(height: 44)
        .stropheSearchGlass(reduceTransparency: reduceTransparency)
        .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.12), radius: 10, y: 4)
        .stropheOnChange(of: isSearchFocused) { isFocused in
            if !isFocused && quickSearchText.isEmpty {
                dismissSearch()
            }
        }
    }

    private var searchTransition: AnyTransition {
        reduceMotion ? .opacity : .offset(y: -8).combined(with: .opacity)
    }

    private func revealSearch() {
        guard !isSearchRevealed else { return }
        #if os(macOS)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                subtitleListSearchOffset = searchReservedHeight
            }
        #else
            // The native rubber-band has already moved the rows roughly 24pt.
            // Supply only the remaining distance until the gesture settles.
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                subtitleListSearchOffset = searchReservedHeight - 24
            }
        #endif
        withAnimation(searchAnimation) {
            isSearchRevealed = true
        }
        #if os(macOS)
            scheduleSearchFocus(delayNanoseconds: 180_000_000)
        #endif
    }

    private func settleSubtitleListBelowSearch() {
        guard isSearchRevealed,
            subtitleListSearchOffset != searchReservedHeight
        else { return }
        withAnimation(searchAnimation) {
            subtitleListSearchOffset = searchReservedHeight
        }
    }

    #if os(macOS)
        private func updateMacSubtitlePullProgress(_ progress: CGFloat) {
            guard !isSearchRevealed else { return }
            let clampedProgress = min(max(progress, 0), 1)
            let targetOffset = searchReservedHeight * clampedProgress
            guard abs(targetOffset - subtitleListSearchOffset) > 0.5 else { return }

            if clampedProgress == 0 {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                    subtitleListSearchOffset = 0
                }
            } else {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.08)) {
                    subtitleListSearchOffset = targetOffset
                }
            }
        }
    #endif

    private func scheduleSearchFocus(delayNanoseconds: UInt64 = 200_000_000) {
        guard isSearchRevealed, !isSearchFocused else { return }
        searchFocusTask?.cancel()
        searchFocusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, isSearchRevealed else { return }
            isSearchFocused = true
        }
    }

    private func dismissSearch() {
        guard isSearchRevealed || !quickSearchText.isEmpty else { return }
        searchFocusTask?.cancel()
        searchFocusTask = nil
        isSearchFocused = false
        withAnimation(searchAnimation) {
            quickSearchText = ""
            isSearchRevealed = false
            subtitleListSearchOffset = 0
        }
    }

    private var searchReservedHeight: CGFloat { 60 }

    private var searchAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
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
            let newEnd = parseEditableTime(editingEndText)
        else { return }
        project.updateSubtitleTime(id: item.id, newStartTime: newStart, newEndTime: newEnd)
        editingTimeItem = nil
    }

    private func karaokeBlockActionBinding(
        for item: SubtitleItem
    ) -> Binding<Bool> {
        Binding(
            get: {
                project.isKaraokeEnabledFromBlockAction(itemID: item.id)
            },
            set: { isEnabled in
                project.setKaraokeFromBlockAction(
                    itemID: item.id,
                    isEnabled: isEnabled
                )
            }
        )
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

private extension View {
    @ViewBuilder
    func strophePullToSearch(
        isAtTop: Binding<Bool>,
        onPullDown: @escaping () -> Void,
        onScrollUp: @escaping () -> Void,
        onScrollEnd: @escaping () -> Void,
        onPullProgress: @escaping (CGFloat) -> Void
    ) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            onScrollGeometryChange(for: ScriptListScrollSignal.self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                let intent: ScriptListScrollSignal.Intent
                if offset < -24 {
                    intent = .revealSearch
                } else if offset > 14 {
                    intent = .hideEmptySearch
                } else {
                    intent = .none
                }

                return ScriptListScrollSignal(
                    isAtTop: offset <= 1,
                    intent: intent
                )
            } action: { _, signal in
                if isAtTop.wrappedValue != signal.isAtTop {
                    isAtTop.wrappedValue = signal.isAtTop
                }

                switch signal.intent {
                case .revealSearch:
                    #if !os(macOS)
                        onPullProgress(1)
                        onPullDown()
                    #endif
                case .hideEmptySearch:
                    onScrollUp()
                case .none:
                    break
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .idle {
                    onScrollEnd()
                }
            }
            .stropheMacScrollWheelSearchTrigger(
                isAtTop: isAtTop.wrappedValue,
                onTrigger: onPullDown,
                onProgress: onPullProgress
            )
        } else {
            simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        onPullProgress(min(max(value.translation.height / 24, 0), 1))
                        if value.translation.height > 24 {
                            onPullDown()
                        } else if value.translation.height < -14 {
                            onScrollUp()
                        }
                    }
                    .onEnded { _ in
                        onPullProgress(0)
                        onScrollEnd()
                    }
            )
        }
    }

    @ViewBuilder
    func stropheMacScrollWheelSearchTrigger(
        isAtTop: Bool,
        onTrigger: @escaping () -> Void,
        onProgress: @escaping (CGFloat) -> Void
    ) -> some View {
        #if os(macOS)
            background {
                MacScrollWheelSearchTrigger(
                    isAtTop: isAtTop,
                    onTrigger: onTrigger,
                    onProgress: onProgress
                )
            }
        #else
            self
        #endif
    }

    @ViewBuilder
    func stropheStableSearchTextFieldLayout() -> some View {
        #if os(macOS)
            frame(height: 22)
                .transaction { transaction in
                    transaction.animation = nil
                }
        #else
            self
        #endif
    }

    @ViewBuilder
    func stropheSearchGlass(reduceTransparency: Bool) -> some View {
        if #available(anyAppleOS 26.0, *), !reduceTransparency {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
        }
    }
}

private struct ScriptListScrollSignal: Equatable {
    enum Intent: Equatable {
        case none
        case revealSearch
        case hideEmptySearch
    }

    let isAtTop: Bool
    let intent: Intent
}

#if os(macOS)
    private struct MacScrollWheelSearchTrigger: NSViewRepresentable {
        let isAtTop: Bool
        let onTrigger: () -> Void
        let onProgress: (CGFloat) -> Void

        func makeNSView(context: Context) -> MacScrollWheelMonitorView {
            let view = MacScrollWheelMonitorView()
            view.isAtTop = isAtTop
            view.onTrigger = onTrigger
            view.onProgress = onProgress
            return view
        }

        func updateNSView(_ nsView: MacScrollWheelMonitorView, context: Context) {
            nsView.isAtTop = isAtTop
            nsView.onTrigger = onTrigger
            nsView.onProgress = onProgress
        }

        static func dismantleNSView(_ nsView: MacScrollWheelMonitorView, coordinator: ()) {
            nsView.removeEventMonitor()
        }
    }

    private final class MacScrollWheelMonitorView: NSView {
        var isAtTop = true
        var onTrigger: () -> Void = {}
        var onProgress: (CGFloat) -> Void = { _ in }

        private var eventMonitor: Any?
        private var accumulatedUpwardDelta: CGFloat = 0
        private var lastEventTimestamp: TimeInterval = 0
        private var lastTriggerTimestamp: TimeInterval = 0
        private var resetWorkItem: DispatchWorkItem?
        private var triggerWorkItem: DispatchWorkItem?
        private var pendingProgress: CGFloat?
        private var isProgressDispatchScheduled = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeEventMonitor()
            } else {
                installEventMonitorIfNeeded()
            }
        }

        func removeEventMonitor() {
            resetWorkItem?.cancel()
            triggerWorkItem?.cancel()
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }

        private func installEventMonitorIfNeeded() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                self?.handleScrollWheel(event)
                return event
            }
        }

        private func handleScrollWheel(_ event: NSEvent) {
            guard isAtTop,
                let window,
                event.window === window,
                bounds.insetBy(dx: 0, dy: -80)
                    .contains(convert(event.locationInWindow, from: nil))
            else {
                resetPullProgress()
                return
            }

            if event.timestamp - lastEventTimestamp > 0.4 {
                resetPullProgress()
            }
            lastEventTimestamp = event.timestamp

            guard event.scrollingDeltaY > 0 else {
                resetPullProgress()
                return
            }

            resetWorkItem?.cancel()
            accumulatedUpwardDelta += event.scrollingDeltaY
            publishProgress(min(accumulatedUpwardDelta / 16, 1))
            schedulePullProgressReset()
            guard accumulatedUpwardDelta >= 16,
                event.timestamp - lastTriggerTimestamp > 0.6,
                triggerWorkItem == nil
            else { return }

            lastTriggerTimestamp = event.timestamp
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.triggerWorkItem = nil
                self.resetWorkItem?.cancel()
                self.resetWorkItem = nil
                guard self.isAtTop else {
                    self.resetPullProgress()
                    return
                }
                self.accumulatedUpwardDelta = 0
                self.onTrigger()
            }
            triggerWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }

        private func resetPullProgress() {
            accumulatedUpwardDelta = 0
            triggerWorkItem?.cancel()
            triggerWorkItem = nil
            publishProgress(0)
        }

        private func schedulePullProgressReset() {
            resetWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.resetPullProgress()
            }
            resetWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: workItem)
        }

        private func publishProgress(_ progress: CGFloat) {
            pendingProgress = progress
            guard !isProgressDispatchScheduled else { return }
            isProgressDispatchScheduled = true

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isProgressDispatchScheduled = false
                guard let progress = self.pendingProgress else { return }
                self.pendingProgress = nil
                self.onProgress(progress)
            }
        }
    }
#endif
