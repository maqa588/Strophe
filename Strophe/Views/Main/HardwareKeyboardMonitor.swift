#if os(iOS)
import SwiftUI
import UIKit

struct StropheHardwareKeyboardMonitor: UIViewRepresentable {
    let project: SubtitleProject

    func makeUIView(context: Context) -> StropheHardwareKeyboardResponder {
        let view = StropheHardwareKeyboardResponder()
        view.project = project
        return view
    }

    func updateUIView(_ uiView: StropheHardwareKeyboardResponder, context: Context) {
        uiView.project = project
        uiView.refreshFirstResponder()
    }
}

@MainActor
final class StropheHardwareKeyboardResponder: UIView {
    weak var project: SubtitleProject?

    private var pressedSlapKeys = Set<String>()
    private static let commandModifiers: UIKeyModifierFlags = [.command]
    private static let commandShiftModifiers: UIKeyModifierFlags = [.command, .shift]
    private static let optionModifiers: UIKeyModifierFlags = [.alternate]
    private static let relevantModifiers: UIKeyModifierFlags = [.shift, .control, .alternate, .command]

    override var canBecomeFirstResponder: Bool { project?.isEditingText != true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshFirstResponder()
    }

    func refreshFirstResponder() {
        guard window != nil else { return }

        if project?.isEditingText == true {
            if isFirstResponder {
                resignFirstResponder()
            }
        } else if !isFirstResponder {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.project?.isEditingText != true else { return }
                self.becomeFirstResponder()
            }
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard project?.isEditingText != true else {
            super.pressesBegan(presses, with: event)
            return
        }

        let handled = presses.contains { press in
            guard let key = press.key else { return false }
            return handleKeyDown(key)
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard project?.isEditingText != true else {
            super.pressesEnded(presses, with: event)
            return
        }

        let handled = presses.contains { press in
            guard let key = press.key else { return false }
            return handleKeyUp(key)
        }

        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressedSlapKeys.removeAll()
        super.pressesCancelled(presses, with: event)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard let project, !project.isEditingText else { return false }

        switch action {
        case #selector(stropheTimelineUndo(_:)):
            return project.canUndo
        case #selector(stropheTimelineRedo(_:)):
            return project.canRedo
        case #selector(stropheTimelineSeekLeft(_:)),
             #selector(stropheTimelineSeekRight(_:)):
            return !project.items.isEmpty
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    @objc func stropheTimelineUndo(_ sender: UICommand) {
        guard let project, !project.isEditingText, project.canUndo else { return }
        project.undo()
    }

    @objc func stropheTimelineRedo(_ sender: UICommand) {
        guard let project, !project.isEditingText, project.canRedo else { return }
        project.redo()
    }

    @objc func stropheTimelineSeekLeft(_ sender: UICommand) {
        guard let project, !project.isEditingText, !project.items.isEmpty else { return }
        project.seekToSubtitleBoundary(.left)
    }

    @objc func stropheTimelineSeekRight(_ sender: UICommand) {
        guard let project, !project.isEditingText, !project.items.isEmpty else { return }
        project.seekToSubtitleBoundary(.right)
    }

    private func handleKeyDown(_ key: UIKey) -> Bool {
        guard let project else { return false }

        let input = key.charactersIgnoringModifiers.lowercased()
        let modifiers = key.modifierFlags.intersection(Self.relevantModifiers)

        if (input == "j" || input == "k"),
           modifiers.isEmpty,
           project.editingMode == .creation {
            guard !pressedSlapKeys.contains(input) else { return true }
            pressedSlapKeys.insert(input)
            project.handleSlapKeyDown(key: input)
            return true
        }

        if modifiers == Self.commandModifiers {
            switch input {
            case "z":
                project.undo(); return true
            case "c":
                guard project.canCopySelectedSubtitleBlocks else { return false }
                project.copySelectedSubtitleBlocks(); return true
            case "x":
                guard project.canCutSelectedSubtitleBlocks else { return false }
                project.cutSelectedSubtitleBlocks(); return true
            case "v":
                guard project.canPasteSubtitleBlocks else { return false }
                project.pasteSubtitleBlocksIntoActiveGroup(); return true
            default:
                break
            }
        }

        if modifiers == Self.commandShiftModifiers, input == "z" {
            project.redo()
            return true
        }

        if modifiers == Self.optionModifiers,
           let number = Int(input),
           (1...9).contains(number),
           let group = StyleAndGroupStore.shared.shortcutGroup(number: number) {
            if project.selectedIDs.isEmpty {
                StyleAndGroupStore.shared.setActiveGroup(group.id)
            } else {
                project.assignSelectedSubtitles(toGroup: group.id)
            }
            return true
        }

        guard modifiers.isEmpty else { return false }

        switch key.keyCode {
        case .keyboardLeftArrow:
            project.seekByFrames(-1)
            return true
        case .keyboardRightArrow:
            project.seekByFrames(1)
            return true
        default:
            break
        }

        switch input {
        case "[":
            project.seekToSubtitleBoundary(.left)
            return true
        case "]":
            project.seekToSubtitleBoundary(.right)
            return true
        case " ":
            project.togglePlayback()
            return true
        case "\u{7F}", "\u{08}":
            guard !project.selectedIDs.isEmpty else { return false }
            project.deleteSubtitles(ids: project.selectedIDs)
            project.selectedIDs.removeAll()
            return true
        default:
            return false
        }
    }

    private func handleKeyUp(_ key: UIKey) -> Bool {
        guard let project else { return false }

        let input = key.charactersIgnoringModifiers.lowercased()
        guard input == "j" || input == "k" else { return false }
        pressedSlapKeys.remove(input)

        if project.editingMode == .creation {
            project.handleSlapKeyUp(key: input)
            return true
        }

        return false
    }
}

extension View {
    func stropheHardwareKeyboardMonitor(project: SubtitleProject) -> some View {
        background(
            StropheHardwareKeyboardMonitor(project: project)
                .frame(width: 1, height: 1)
                .opacity(0.01)
        )
    }
}
#else
import SwiftUI

extension View {
    func stropheHardwareKeyboardMonitor(project: SubtitleProject) -> some View {
        self
    }
}
#endif
