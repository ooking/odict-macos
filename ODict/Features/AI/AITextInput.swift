import SwiftUI
import AppKit

/// Native multiline editor, no global event monitor; IME owns Return while composing.
struct AITextInput: NSViewRepresentable {
    @ObservedObject private var appearance = ReadingAppearanceStore.shared
    let text: String
    let focusRequest: UUID
    var allowsFocus: Bool
    let isEditable: Bool
    let changed: (String) -> Void
    let rejected: () -> Void
    let measuredHeight: (CGFloat) -> Void
    let submit: () -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MeasuringScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let editor = Editor(frame: NSRect(x: 0, y: 0, width: 1, height: 35))
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
        scroll.onLayout = { [weak coordinator = context.coordinator] view in coordinator?.measure(view) }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? Editor else { return }
        editor.submit = submit; editor.cancel = cancel
        editor.isEditable = isEditable
        editor.isSelectable = true
        editor.setAccessibilityHelp(isEditable ? "回车查询，Shift 加回车换行" : "正在翻译，结束或停止后可以编辑")
        if editor.string != text, !editor.hasMarkedText() { editor.string = text }
        context.coordinator.fontStyler.apply(to: editor, appearance: appearance.value)
        context.coordinator.measure(scroll)
        if context.coordinator.lastFocus != focusRequest, allowsFocus, isEditable {
            context.coordinator.lastFocus = focusRequest
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.window?.isKeyWindow == true, editor.isEditable else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AITextInput
        var lastFocus: UUID?
        let fontStyler = InputFontStyler()
        private var lastHeight: CGFloat = 0
        init(_ parent: AITextInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            fontStyler.apply(to: editor, appearance: parent.appearance.value)
            parent.changed(editor.string)
            if let scroll = editor.enclosingScrollView { measure(scroll) }
        }
        func measure(_ scroll: NSScrollView) {
            guard scroll.window != nil, scroll.contentSize.width > 1, let editor = scroll.documentView as? NSTextView,
                  let manager = editor.layoutManager, let container = editor.textContainer else { return }
            let width = scroll.contentSize.width
            if abs(editor.frame.width - width) > 0.5 {
                editor.setFrameSize(NSSize(width: width, height: max(35, editor.frame.height)))
            }
            manager.ensureLayout(for: container)
            let lineHeight = InputFontStyler.lineHeight
            let inset = editor.textContainerInset.height * 2
            let height = min(lineHeight * 3 + inset, max(lineHeight + inset, ceil(manager.usedRect(for: container).height) + inset))
            guard abs(lastHeight - height) > 0.5 else { return }
            lastHeight = height
            DispatchQueue.main.async { [weak self, weak scroll] in
                guard let self, scroll?.window != nil else { return }
                self.parent.measuredHeight(height)
            }
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard parent.isEditable else { return false }
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
    final class MeasuringScrollView: NSScrollView {
        var onLayout: ((NSScrollView) -> Void)?
        override func layout() { super.layout(); onLayout?(self) }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onLayout?(self) }
    }
    final class Editor: NSTextView {
        var submit: (() -> Void)?
        var cancel: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if !hasMarkedText() {
                if event.keyCode == 36 || event.keyCode == 76 {
                    guard isEditable else { return }
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
