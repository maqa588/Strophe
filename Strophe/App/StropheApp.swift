import SwiftUI
import AVFoundation

@main
struct StropheApp: App {
    init() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set audio session category: \(error)")
        }
        #endif
        
        // Clean up any files left over from previous runs (e.g. crashes or forced quits)
        TempCleanupHelper.cleanupTempDirectory()
        // Register to clean up files when gracefully exiting (including Command+Q)
        TempCleanupHelper.registerForTerminationCleanup()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1200, height: 750)
        .commands {
            CommandGroup(replacing: .newItem) {
                // Custom file menu commands can go here
            }
        }
        #endif
    }
}
