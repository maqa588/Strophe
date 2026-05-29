import SwiftUI
import AVFoundation
#if os(iOS)
import Darwin
#endif

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
        IOSStderrRedirector.install()

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
            StropheMenuBar(project: project)
        }
        #endif
    }
}

#if os(iOS)
private enum IOSStderrRedirector {
    static func install() {
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }

        let logsURL = cachesURL.appendingPathComponent("Logs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        } catch {
            return
        }

        let stderrURL = logsURL.appendingPathComponent("strophe-stderr.log")
        stderrURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            fflush(stderr)
            _ = freopen(path, "a", stderr)
            setvbuf(stderr, nil, _IOLBF, 0)
        }
    }
}
#endif

extension Notification.Name {
    static let stropheOpenProject = Notification.Name("com.strophe.openProject")
    static let stropheImportMedia = Notification.Name("com.strophe.importMedia")
    static let stropheSaveProject = Notification.Name("com.strophe.saveProject")
    static let stropheSaveProjectAs = Notification.Name("com.strophe.saveProjectAs")
    static let stropheShowAbout = Notification.Name("com.strophe.showAbout")
    static let strophePasteScript = Notification.Name("com.strophe.pasteScript")
    static let stropheImportScriptFile = Notification.Name("com.strophe.importScriptFile")
    static let stropheStartSpeechRecognition = Notification.Name("com.strophe.startSpeechRecognition")
    static let stropheOpenProjectWithURL = Notification.Name("com.strophe.openProjectWithURL")
    static let stropheShowSaveOnQuitAlert = Notification.Name("com.strophe.showSaveOnQuitAlert")
    static let stropheScrubTimeChanged = Notification.Name("com.strophe.scrubTimeChanged")
}
