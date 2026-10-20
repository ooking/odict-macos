import SwiftUI
import AppKit

// Handle field-editor commands rather than monitoring keys globally. Marked text
// belongs to the input method, including its arrow and Return key handling.
struct CandidateSearchField: NSViewRepresentable {
    let text: String
    let changed: (String, Bool) -> Void
    @Binding var focused: Bool
    let focusRequest: UUID
    let move: (Int) -> Bool
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = .labelColor
        field.placeholderString = "查单词、短语或中文"
        field.isEditable = true
        field.isSelectable = true
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel("查词输入框")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: SearchTextField, context: Context) {
        context.coordinator.parent = self
        // Avoid replacing the field editor's marked text during IME composition.
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if field.stringValue != text, !composing {
            field.stringValue = text
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            field.requestFocus()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CandidateSearchField
        var lastFocusRequest: UUID?
        init(_ parent: CandidateSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
            parent.changed(field.stringValue, composing)
        }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focused = false }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch NSStringFromSelector(commandSelector) {
            case "moveDown:": return parent.move(1)
            case "moveUp:": return parent.move(-1)
            case "insertNewline:": parent.submit(); return true
            case "cancelOperation:": parent.cancel(); return true
            default: return false
            }
        }
    }

    final class SearchTextField: NSTextField {
        private var pendingFocus = false

        func requestFocus() {
            pendingFocus = true
            focusWhenAttached()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusWhenAttached()
        }

        private func focusWhenAttached() {
            guard pendingFocus, window != nil else { return }
            pendingFocus = false
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
