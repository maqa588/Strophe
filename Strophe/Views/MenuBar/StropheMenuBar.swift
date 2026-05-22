import SwiftUI

struct StropheMenuBar: Commands {
    @ObservedObject var project: SubtitleProject
    
    var body: some Commands {
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
        
        CommandGroup(replacing: .saveItem) {
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
        
        CommandGroup(replacing: .appInfo) {
            Button(String(localized: "About Strophe")) {
                NotificationCenter.default.post(name: .stropheShowAbout, object: nil)
            }
        }
    }
}
