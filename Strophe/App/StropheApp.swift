import SwiftUI
import AVFoundation

#if os(macOS)
class AppDelegate: NSObject, NSApplicationDelegate {
    weak var project: SubtitleProject?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let project = project, project.isDirty else {
            return .terminateNow
        }
        NotificationCenter.default.post(name: .stropheShowSaveOnQuitAlert, object: nil)
        return .terminateLater
    }
}
#endif

@main
struct StropheApp: App {
    @StateObject private var project = SubtitleProject()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    
    init() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set audio session category: \(error)")
        }
        #endif
        
        TempCleanupHelper.performStartupCleanupIfNeeded()
        TempCleanupHelper.registerForTerminationCleanup()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(project: project)
                #if os(macOS)
                .onAppear { appDelegate.project = project }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 750)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(String(localized: "Open")) {
                    NotificationCenter.default.post(name: .stropheImportMedia, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                
                Button(String(localized: "Open Strophe Project...")) {
                    NotificationCenter.default.post(name: .stropheOpenProject, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            
            CommandGroup(after: .newItem) {
                Button(String(localized: "Save")) {
                    NotificationCenter.default.post(name: .stropheSaveProject, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(project.videoURL == nil && project.items.isEmpty)
                
                Button(String(localized: "Save As...")) {
                    NotificationCenter.default.post(name: .stropheSaveProjectAs, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(project.videoURL == nil && project.items.isEmpty)
            }
        }
        #endif
    }
}

extension Notification.Name {
    static let stropheOpenProject = Notification.Name("com.strophe.openProject")
    static let stropheImportMedia = Notification.Name("com.strophe.importMedia")
    static let stropheSaveProject = Notification.Name("com.strophe.saveProject")
    static let stropheSaveProjectAs = Notification.Name("com.strophe.saveProjectAs")
    static let strophePasteScript = Notification.Name("com.strophe.pasteScript")
    static let stropheImportScriptFile = Notification.Name("com.strophe.importScriptFile")
    static let stropheOpenProjectWithURL = Notification.Name("com.strophe.openProjectWithURL")
    static let stropheShowSaveOnQuitAlert = Notification.Name("com.strophe.showSaveOnQuitAlert")
}
