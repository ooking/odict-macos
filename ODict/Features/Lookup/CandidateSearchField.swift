import SwiftUI
import AppKit

// Handle field-editor commands rather than monitoring keys globally. Marked text
// belongs to the input method, including its arrow and Return key handling.
struct CandidateSearchField: NSViewRepresentable {
    @ObservedObject private var appearance = ReadingAppearanceStore.shared
    let text: String
    let changed: (String, Bool) -> Void
    @Binding var focused: Bool
    let focusRequest: UUID
    var allowsFocus = true
    let move: (Int) -> Bool
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AppTypography.search
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
        field.allowsAutomaticFocus = allowsFocus
        // Avoid replacing the field editor's marked text during IME composition.
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if field.stringValue != text, !composing {
            field.stringValue = text
        }
        if !composing { context.coordinator.fontStyler.apply(to: field, appearance: appearance.value) }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            if allowsFocus { field.requestFocus() }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CandidateSearchField
        var lastFocusRequest: UUID?
        let fontStyler = InputFontStyler()
        init(_ parent: CandidateSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
            if !composing { fontStyler.apply(to: field, appearance: parent.appearance.value) }
            parent.changed(field.stringValue, composing)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            // AppKit shares the field editor with other controls, which may
            // have replaced its attributes since this field last had focus.
            fontStyler.invalidate()
            if let field = notification.object as? NSTextField {
                fontStyler.apply(to: field, appearance: parent.appearance.value)
            }
            parent.focused = true
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField {
                fontStyler.apply(to: field, appearance: parent.appearance.value)
            }
            parent.focused = false
        }

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
        var allowsAutomaticFocus = true { didSet { if !allowsAutomaticFocus { pendingFocus = false } } }

        func requestFocus() {
            pendingFocus = true
            focusWhenAttached()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusWhenAttached()
        }

        private func focusWhenAttached() {
            guard pendingFocus, allowsAutomaticFocus, window != nil else { return }
            pendingFocus = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.allowsAutomaticFocus, let window = self.window, window.isKeyWindow else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
