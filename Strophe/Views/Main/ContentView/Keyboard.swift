//
//  ContentView+Keyboard.swift
//  Strophe
//

import SwiftUI
import UniformTypeIdentifiers

extension ContentView {

    // MARK: - Keyboard Monitor (macOS)

    func setupKeyboardMonitor() {
        #if os(macOS)
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            if let keyWindow = NSApp.keyWindow,
               let responder = keyWindow.firstResponder {
                let className = String(describing: type(of: responder))
                if responder is NSText || className.contains("Text") || className.contains("Field") || className.contains("Editor") || className.contains("Search") {
                    return event
                }
            }

            if project.isEditingText { return event }

            let isKeyDown = event.type == .keyDown
            let isKeyUp   = event.type == .keyUp

            if let chars = event.charactersIgnoringModifiers?.lowercased(),
               chars == "j" || chars == "k" {
                if project.editingMode == .creation {
                    if isKeyDown, !event.isARepeat { project.handleSlapKeyDown(key: chars) }
                    else if isKeyUp { project.handleSlapKeyUp(key: chars) }
                    return nil
                }
            }

            if isKeyDown {
                let mod = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if mod == .command || mod == [.command, .shift] {
                    // Handled by main menu commands with proper text/timeline routing
                    return event
                }
                if mod.isEmpty {
                    switch event.keyCode {
                    case 33:
                        project.seekToSubtitleBoundary(.left); return nil
                    case 30:
                        project.seekToSubtitleBoundary(.right); return nil
                    case 123:
                        project.seekByFrames(-1); return nil
                    case 124:
                        project.seekByFrames(1); return nil
                    default:
                        break
                    }
                }
                if mod == .option,
                   let rawKey = event.charactersIgnoringModifiers,
                   let number = Int(rawKey),
                   (1...9).contains(number),
                   let group = StyleAndGroupStore.shared.shortcutGroup(number: number) {
                    if project.selectedIDs.isEmpty {
                        StyleAndGroupStore.shared.setActiveGroup(group.id)
                    } else {
                        project.assignSelectedSubtitles(toGroup: group.id)
                    }
                    return nil
                }
                switch event.charactersIgnoringModifiers {
                case " ":
                    project.togglePlayback(); return nil
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

    #if os(macOS)
    func removeKeyboardMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }
    #endif
}
