import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SubtitleTextEditSheet: View {
    let title: String
    @Binding var text: String
    @Binding var isPresented: Bool
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.stropheText)

            SubtitleTextEditingView(text: $text)
                .frame(minHeight: 130)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.stropheBlue, lineWidth: 2)
                )

            HStack(spacing: 14) {
                Button(String(localized: "Cancel")) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "确定")) {
                    onConfirm()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
        .background(Color.stropheBackground)
    }
}

#if os(macOS)
struct SubtitleTextEditingView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.08)

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 15)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        DispatchQueue.main.async {
            scrollView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        DispatchQueue.main.async {
            if scrollView.window?.firstResponder !== textView {
                scrollView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
#else
struct SubtitleTextEditingView: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 15))
            .focused($isFocused)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .onAppear {
                isFocused = true
            }
    }
}
#endif
