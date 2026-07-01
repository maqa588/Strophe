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
        #if os(macOS)
        if #unavailable(macOS 14.0) {
            // Ventura's NSTableView row-height estimation can request stale rows during SwiftUI List tab swaps.
            UserDefaults.standard.set(false, forKey: "NSTableViewCanEstimateRowHeights")
        }
        #endif

        #if os(iOS)
        IOSStderrRedirector.install()
        StropheAudioSession.configureForPlayback()
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
        #endif
        #if os(macOS) || os(iOS)
        .commands {
            StropheNavBarCommands(project: project)
        }
        #endif
    }
}

#if os(iOS)
private enum StropheAudioSession {
    static func configureForPlayback() {
        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(.playback, mode: .default)
        } catch {
            print("Failed to set audio session category: \(error)")
            return
        }

        if #available(anyAppleOS 27.0, *) {
            session.activate(options: []) { activated, error in
                if let error {
                    print("Failed to activate audio session: \(error)")
                } else if !activated {
                    print("Audio session activation did not complete")
                }
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try session.setActive(true)
                } catch {
                    print("Failed to activate audio session: \(error)")
                }
            }
        }
    }
}

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
