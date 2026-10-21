import SwiftUI
import AppKit

/// Native multiline editor, no global event monitor; IME owns Return while composing.
struct AITextInput: NSViewRepresentable {
    let text: String
    let focusRequest: UUID
    var allowsFocus: Bool
    let changed: (String) -> Void
    let rejected: () -> Void
    let submit: () -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let editor = Editor()
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.drawsBackground = false
        editor.font = AppTypography.search
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 2, height: 6)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("AI 输入，回车查询，Shift 加回车换行")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? Editor else { return }
        editor.submit = submit; editor.cancel = cancel
        if editor.string != text, !editor.hasMarkedText() { editor.string = text }
        if context.coordinator.lastFocus != focusRequest, allowsFocus {
            context.coordinator.lastFocus = focusRequest
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.window?.isKeyWindow == true else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AITextInput
        var lastFocus: UUID?
        init(_ parent: AITextInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            parent.changed(editor.string)
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            // Bound accidental large pastes before NSTextView allocates layout for them.
            guard replacementString.utf16.prefix(16001).count <= 16000,
                  textView.string.utf16.count - affectedCharRange.length + replacementString.utf16.count <= 16000 else {
                parent.rejected()
                return false
            }
            return true
        }
    }
    final class Editor: NSTextView {
        var submit: (() -> Void)?
        var cancel: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if !hasMarkedText() {
                if event.keyCode == 36 || event.keyCode == 76 {
                    if event.modifierFlags.contains(.shift) { insertNewlineIgnoringFieldEditor(nil) }
                    else { submit?() }
                    return
                }
                if event.keyCode == 53 { cancel?(); return }
            }
            super.keyDown(with: event)
        }
    }
}
