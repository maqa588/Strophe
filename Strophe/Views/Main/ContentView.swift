//
//  ContentView.swift
//  Strophe
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var project: SubtitleProject
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var navigationPath = NavigationPath()
    @State private var isShowingSaveStrophe = false
    @State private var saveStropheDefaultName = "project"
    @State private var isShowingOpenProject = false
    @State private var isShowingImportMedia = false

    var body: some View {
        Group {
            if sizeClass == .compact {
                NavigationStack(path: $navigationPath) {
                    MainContentView(project: project, isCompact: true, path: $navigationPath)
                        .navigationDestination(for: String.self) { value in
                            if value == "script" {
                                ScriptListView(project: project, isCompact: true, path: $navigationPath)
                            }
                        }
                }
                .onAppear {
                    setupKeyboardMonitor()
                    setupMenuNotifications()
                }
            } else {
                NavigationSplitView {
                    ScriptListView(project: project, isCompact: false, path: .constant(NavigationPath()))
                        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
                } detail: {
                    MainContentView(project: project, isCompact: false, path: .constant(NavigationPath()))
                }
                .onAppear {
                    setupKeyboardMonitor()
                    setupMenuNotifications()
                }
            }
        }
        .tint(Color.stropheAccent)
        .fileImporter(
            isPresented: $isShowingImportMedia,
            allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie, .audio, .mp3, .item, UTType(filenameExtension: "strophe") ?? .json],
            allowsMultipleSelection: false
        ) { result in
            handleImportMedia(result)
        }
        .fileImporter(
            isPresented: $isShowingOpenProject,
            allowedContentTypes: [UTType(filenameExtension: "strophe") ?? .json],
            allowsMultipleSelection: false
        ) { result in
            handleOpenProject(result)
        }
        .fileExporter(
            isPresented: $isShowingSaveStrophe,
            document: project.stropheDocument,
            contentType: UTType(filenameExtension: "strophe") ?? .json,
            defaultFilename: saveStropheDefaultName
        ) { result in
            if case .success(let url) = result {
                Task {
                    try? await project.saveStrophe(to: url)
                    project.startAutoSave()
                }
            }
        }
    }

    private func setupKeyboardMonitor() {
        #if os(macOS)
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            if project.isEditingText {
                return event
            }
            
            let isKeyDown = event.type == .keyDown
            let isKeyUp = event.type == .keyUp
            
            if let chars = event.charactersIgnoringModifiers?.lowercased(), chars == "j" || chars == "k" {
                if project.editingMode == .creation {
                    if isKeyDown {
                        project.handleSlapKeyDown(key: chars)
                    } else if isKeyUp {
                        project.handleSlapKeyUp(key: chars)
                    }
                    return nil
                }
            }
            
            if isKeyDown {
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                
                if modifiers == .command, event.charactersIgnoringModifiers == "z" {
                    project.undo()
                    return nil
                }
                
                if modifiers == [.command, .shift], event.charactersIgnoringModifiers == "Z" {
                    project.redo()
                    return nil
                }
                
                switch event.charactersIgnoringModifiers {
                case " ":
                    project.togglePlayback()
                    return nil
                case "\u{7F}", "\u{08}":
                    if !project.selectedIDs.isEmpty {
                        project.deleteSubtitles(ids: project.selectedIDs)
                        project.selectedIDs.removeAll()
                        return nil
                    }
                    return event
                default:
                    return event
                }
            }
            
            return event
        }
        #endif
    }
    
    private func setupMenuNotifications() {
        NotificationCenter.default.addObserver(
            forName: .stropheImportMedia,
            object: nil,
            queue: .main
        ) { _ in
            isShowingImportMedia = true
        }
        NotificationCenter.default.addObserver(
            forName: .stropheOpenProject,
            object: nil,
            queue: .main
        ) { _ in
            isShowingOpenProject = true
        }
        NotificationCenter.default.addObserver(
            forName: .stropheSaveProject,
            object: nil,
            queue: .main
        ) { [weak project] _ in
            Task { @MainActor [weak project] in
                guard let project = project else { return }
                let existingURL = project.projectURL
                if let url = existingURL {
                    try? await project.saveStrophe(to: url)
                } else {
                    let baseName = project.documentDisplayName
                    saveStropheDefaultName = baseName.isEmpty ? "project" : baseName
                    isShowingSaveStrophe = true
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: .stropheSaveProjectAs,
            object: nil,
            queue: .main
        ) { [weak project] _ in
            Task { @MainActor [weak project] in
                guard let project = project else { return }
                let baseName = project.documentDisplayName
                saveStropheDefaultName = baseName.isEmpty ? "project" : baseName
                isShowingSaveStrophe = true
            }
        }
    }
    
    private func handleImportMedia(_ result: Result<[URL], Error>) {
        DispatchQueue.main.async {
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if url.pathExtension.lowercased() == "strophe" {
                    Task {
                        try? await project.loadStrophe(from: url)
                        project.startAutoSave()
                    }
                    return
                }
                project.pause()
                TempCleanupHelper.cleanupTempDirectory()
                project.resetForNewMedia()
                project.prepareMediaAccess(for: url)
                project.videoURL = url
            case .failure(let error):
                print("Import failed: \(error.localizedDescription)")
            }
        }
    }
    
    private func handleOpenProject(_ result: Result<[URL], Error>) {
        DispatchQueue.main.async {
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                try? await project.loadStrophe(from: url)
                project.startAutoSave()
            }
        }
    }
}

extension Notification.Name {
    static let togglePlayback = Notification.Name("com.swiftsub.togglePlayback")
    static let requestCurrentTime = Notification.Name("com.swiftsub.requestCurrentTime")
    static let seekDelta = Notification.Name("com.swiftsub.seekDelta")
    static let changePlaybackSpeed = Notification.Name("com.swiftsub.changePlaybackSpeed")
}

#Preview {
    ContentView(project: SubtitleProject())
}
