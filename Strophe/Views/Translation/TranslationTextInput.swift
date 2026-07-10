import SwiftUI

#if os(macOS)
import AppKit

struct TranslationTextInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 17)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 2, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        
        context.coordinator.text = $text
        context.coordinator.selection = $selection
        context.coordinator.onSubmit = onSubmit
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        let safeSelection = clampedSelection(selection, utf16Count: (text as NSString).length)
        if textView.selectedRange() != safeSelection {
            textView.setSelectedRange(safeSelection)
        }
    }

    private func clampedSelection(_ range: NSRange, utf16Count: Int) -> NSRange {
        let location = min(max(0, range.location), utf16Count)
        let length = min(max(0, range.length), utf16Count - location)
        return NSRange(location: location, length: length)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var selection: Binding<NSRange>
        var onSubmit: () -> Void
        var isUpdating = false

        init(text: Binding<String>, selection: Binding<NSRange>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.selection = selection
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating else { return }
            guard let textView = notification.object as? NSTextView else { return }
            if text.wrappedValue != textView.string {
                text.wrappedValue = textView.string
            }
            let newSelection = textView.selectedRange()
            if selection.wrappedValue != newSelection {
                selection.wrappedValue = newSelection
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating else { return }
            guard let textView = notification.object as? NSTextView else { return }
            let newSelection = textView.selectedRange()
            if selection.wrappedValue != newSelection {
                selection.wrappedValue = newSelection
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true { return false }
            onSubmit()
            return true
        }
    }
}

#else
import UIKit

struct TranslationTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection, onSubmit: onSubmit)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.text = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 2, bottom: 6, right: 2)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        
        context.coordinator.text = $text
        context.coordinator.selection = $selection
        context.coordinator.onSubmit = onSubmit
        if textView.text != text {
            textView.text = text
        }
        let safeSelection = clampedSelection(selection, utf16Count: (text as NSString).length)
        if textView.selectedRange != safeSelection {
            textView.selectedRange = safeSelection
        }
    }

    private func clampedSelection(_ range: NSRange, utf16Count: Int) -> NSRange {
        let location = min(max(0, range.location), utf16Count)
        let length = min(max(0, range.length), utf16Count - location)
        return NSRange(location: location, length: length)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var selection: Binding<NSRange>
        var onSubmit: () -> Void
        var isUpdating = false

        init(text: Binding<String>, selection: Binding<NSRange>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.selection = selection
            self.onSubmit = onSubmit
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdating else { return }
            if text.wrappedValue != textView.text {
                text.wrappedValue = textView.text
            }
            if selection.wrappedValue != textView.selectedRange {
                selection.wrappedValue = textView.selectedRange
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isUpdating else { return }
            if selection.wrappedValue != textView.selectedRange {
                selection.wrappedValue = textView.selectedRange
            }
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            if replacement == "\n" {
                onSubmit()
                return false
            }
            return true
        }
    }
}
#endif
