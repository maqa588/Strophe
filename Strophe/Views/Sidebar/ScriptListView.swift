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
    @State private var isShowingAutoCaption = false
    
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
        .onChange(of: isShowingInput) { _, newValue in
            project.isEditingText = newValue
        }
        .alert(String(localized: "编辑字幕内容"), isPresented: $isEditingText) {
            TextField("输入新字幕文本", text: $editingText)
            Button("确定") {
                if let item = editingItem {
                    project.updateSubtitleText(id: item.id, text: editingText)
                }
                editingItem = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                editingItem = nil
            }
        }
        .onChange(of: isEditingText) { _, newValue in
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
        .onChange(of: isShowingFileImporter) { _, newValue in
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
        .onChange(of: isShowingAutoCaption) { _, newValue in
            project.isEditingText = newValue
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Script", systemImage: "doc.text")
        } description: {
            Text("Paste your script to start marking timestamps.")
        } actions: {
            VStack(spacing: 8) {
                Button("Import Script…") {
                    isShowingImportOptions = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stropheAccent)
                
                Button("Speech Recognition…") {
                    isShowingAutoCaption = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stropheAccent)
            }
        }
    }

    // MARK: - Script List
    private var scriptList: some View {
        ScrollViewReader { scrollProxy in
            List(Array(project.items.enumerated()), id: \.element.id, selection: $project.selectedIDs) { index, item in
                SubtitleRow(
                    item: item,
                    index: index,
                    isActive: item.id == project.scrollTargetID,
                    isOverlapping: project.isItemOverlapping(id: item.id)
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .listRowSeparator(.hidden)
                .id(item.id)
                .tag(item.id)
                .contextMenu {
                    Button(action: {
                        editingItem = item
                        editingText = item.text
                        isEditingText = true
                    }) {
                        Label("编辑内容", systemImage: "pencil")
                    }
                    
                    Button(role: .destructive, action: {
                        project.deleteSubtitle(id: item.id)
                    }) {
                        Label("删除字幕", systemImage: "trash")
                    }
                }
                .disabled(project.editingMode == .creation)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .onDeleteCommandIfSupported {
                if !project.selectedIDs.isEmpty {
                    project.deleteSubtitles(ids: project.selectedIDs)
                    project.selectedIDs.removeAll()
                }
            }
            .onChange(of: project.scrollTargetID) { _, newID in
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
}
