import SwiftUI
import AVFoundation
#if os(iOS)
import Darwin
import UIKit
class StropheIOSAppDelegate: NSObject, UIApplicationDelegate {
    weak var project: SubtitleProject?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        installMainMenuBarIfAvailable()
        return true
    }

    @available(iOS 26.0, *)
    private func configureMainMenuBar() {
        let configuration = UIMainMenuSystem.Configuration()
        configuration.documentPreference = .removed
        configuration.printingPreference = .removed
        UIMainMenuSystem.shared.setBuildConfiguration(configuration)
    }

    func rebuildMainMenuBarIfAvailable() {
        if #available(iOS 26.0, *) {
            UIMainMenuSystem.shared.setNeedsRebuild()
        }
    }

    private func installMainMenuBarIfAvailable() {
        if #available(iOS 26.0, *) {
            configureMainMenuBar()
        }
    }
}
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Re-show the welcome window when user clicks Dock icon with no visible windows
            if let welcomeWindow = NSApplication.shared.windows.first(where: {
                $0.identifier?.rawValue.contains("welcome") == true
            }) {
                welcomeWindow.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
        return true
    }

    func application(_ sender: NSApplication, shouldRestoreState coder: NSCoder) -> Bool {
        return false
    }
}
#endif

@main
struct StropheApp: App {
    @StateObject private var project = SubtitleProject()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #elseif os(iOS)
    @UIApplicationDelegateAdaptor(StropheIOSAppDelegate.self) var appDelegate
    #elseif os(visionOS)
    @StateObject private var workspace = SpatialWorkspaceModel()
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
        #endif

        #if os(iOS) || os(visionOS)
        StropheAudioSession.configureForPlayback()
        #endif
        
        TempCleanupHelper.performStartupCleanupIfNeeded()
        TempCleanupHelper.registerForTerminationCleanup()
    }

    var body: some Scene {
        #if os(macOS)
        Window("title_welcome", id: "welcome") {
            Group {
                if ProcessInfo.processInfo.arguments.contains(
                    "-ui-testing-open-editor"
                ) {
                    // Keep the editor in the initially materialized window for
                    // UI tests. Opening a second scene from the welcome
                    // window's first onAppear can race with closing that
                    // window and leave XCTest with no accessible window.
                    WelcomeRouterView(project: project)
                        .frame(width: 1_200, height: 750)
                } else {
                    MacWelcomeSceneView(project: project)
                        .ignoresSafeArea()
                }
            }
                .onAppear { appDelegate.project = project }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 920, height: 620)

        WindowGroup("tab_project", id: "editor") {
            ContentView(project: project)
                .onAppear { appDelegate.project = project }
        }
        .defaultSize(width: 1200, height: 750)
        .commands {
            StropheNavBarCommands(project: project)
        }
        #else
        #if os(iOS)
        WindowGroup {
            WelcomeRouterView(project: project)
                .onAppear {
                    appDelegate.project = project
                    appDelegate.rebuildMainMenuBarIfAvailable()
                }
        }
        .commands {
            StropheNavBarCommands(project: project)
        }
        #elseif os(visionOS)
        WindowGroup("Strophe", id: SpatialWindowID.editor) {
            WelcomeRouterView(project: project)
                .environmentObject(workspace)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)

        WindowGroup("vp_window_video", id: SpatialWindowID.video) {
            VideoWindowRoot(project: project)
                .environmentObject(workspace)
                .frame(minWidth: 640, minHeight: 360)
        }
        .defaultSize(width: 960, height: 540)
        .windowResizability(.contentMinSize)
        .defaultWindowPlacement { _, context in
            guard let editor = context.windows.first(where: { $0.id == SpatialWindowID.editor }) else {
                return WindowPlacement()
            }
            return WindowPlacement(.trailing(editor))
        }

        WindowGroup("vp_window_timeline", id: SpatialWindowID.timeline) {
            TimelineWindowRoot(project: project)
                .environmentObject(workspace)
                .frame(minWidth: 900, minHeight: 320)
        }
        .defaultSize(width: 1200, height: 420)
        .windowResizability(.contentMinSize)
        .defaultWindowPlacement { _, context in
            guard let editor = context.windows.first(where: { $0.id == SpatialWindowID.editor }) else {
                return WindowPlacement()
            }
            return WindowPlacement(.below(editor))
        }

        WindowGroup("vp_window_teleprompter", id: SpatialWindowID.teleprompter) {
            TeleprompterWindowRoot(project: project)
                .environmentObject(workspace)
                .frame(minWidth: 640, minHeight: 400)
        }
        .defaultSize(width: 760, height: 480)
        .windowResizability(.contentMinSize)
        .defaultWindowPlacement { _, _ in
            WindowPlacement(.utilityPanel)
        }

        WindowGroup("vp_window_style", id: SpatialWindowID.style, for: UUID.self) { $styleID in
            if let styleID {
                StyleWindowRoot(project: project, styleID: styleID)
                    .frame(minWidth: 400, minHeight: 560)
            }
        }
        .defaultSize(width: 460, height: 720)
        .windowResizability(.contentMinSize)
        .defaultWindowPlacement { _, _ in
            WindowPlacement(.utilityPanel)
        }

        WindowGroup("vp_window_cinema", id: SpatialWindowID.cinema) {
            CinemaWindowRoot(project: project)
                .environmentObject(workspace)
                .frame(minWidth: 720, minHeight: 405)
        }
        .defaultSize(width: 1280, height: 720)
        .windowResizability(.contentMinSize)

        WindowGroup("vp_window_volume", id: SpatialWindowID.volume) {
            VolumePreviewRoot(project: project)
                .environmentObject(workspace)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 0.9, height: 0.6, depth: 0.12, in: .meters)

        ImmersiveSpace(id: SpatialWindowID.immersive) {
            ImmersiveCinemaView(project: project)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        #else
        WindowGroup {
            WelcomeRouterView(project: project)
        }
        #endif
        #endif
    }
}

#if os(iOS) || os(visionOS)
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

#endif

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
    static let stropheNewProject = Notification.Name("com.strophe.newProject")
    static let stropheReplaceMedia = Notification.Name("com.strophe.replaceMedia")
    static let stropheOpenProject = Notification.Name("com.strophe.openProject")
    static let stropheImportMedia = Notification.Name("com.strophe.importMedia")
    static let stropheSaveProject = Notification.Name("com.strophe.saveProject")
    static let stropheSaveProjectAs = Notification.Name("com.strophe.saveProjectAs")
    static let stropheShowAbout = Notification.Name("com.strophe.showAbout")
    static let stropheShowCurrentMediaInfo = Notification.Name("com.strophe.showCurrentMediaInfo")
    static let strophePasteScript = Notification.Name("com.strophe.pasteScript")
    static let stropheImportScriptFile = Notification.Name("com.strophe.importScriptFile")
    static let stropheStartSpeechRecognition = Notification.Name("com.strophe.startSpeechRecognition")
    static let stropheOpenModelSettings = Notification.Name("com.strophe.openModelSettings")
    static let stropheStartSubtitleTranslation = Notification.Name("com.strophe.startSubtitleTranslation")
    static let stropheStartBatchTranslation = Notification.Name("com.strophe.startBatchTranslation")
    static let stropheConvertSelectedToPinyin = Notification.Name("com.strophe.convertSelectedToPinyin")
    static let stropheOpenAutoLineWrap = Notification.Name("com.strophe.openAutoLineWrap")
    static let stropheOpenKaraokeBatchRecognition = Notification.Name("com.strophe.openKaraokeBatchRecognition")
    static let stropheOpenEditingTools = Notification.Name("com.strophe.openEditingTools")
    static let stropheShowProjectMarkers = Notification.Name("com.strophe.showProjectMarkers")
    static let stropheOpenBilingualEditor = Notification.Name("com.strophe.openBilingualEditor")
    static let stropheOpenProjectWithURL = Notification.Name("com.strophe.openProjectWithURL")
    static let stropheShowSaveOnQuitAlert = Notification.Name("com.strophe.showSaveOnQuitAlert")
    static let stropheScrubTimeChanged = Notification.Name("com.strophe.scrubTimeChanged")
    static let stropheShowWelcome = Notification.Name("com.strophe.showWelcome")
    static let stropheShowSuccessToast = Notification.Name("com.strophe.showSuccessToast")
    static let stropheExportSoftSubtitles = Notification.Name("com.strophe.exportSoftSubtitles")
    static let stropheExportEmbeddedSubtitles = Notification.Name("com.strophe.exportEmbeddedSubtitles")
    static let stropheExportHardSubtitles = Notification.Name("com.strophe.exportHardSubtitles")
    static let stropheExportAlphaVideo = Notification.Name("com.strophe.exportAlphaVideo")
    static let stropheExportDelivery = Notification.Name("com.strophe.exportDelivery")
}
