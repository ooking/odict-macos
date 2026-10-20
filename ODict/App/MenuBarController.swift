import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var onToggle: (() -> Void)?

    override init() {
        super.init()
        let image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "ODict 查词")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "ODict — 点击查词"
        item.button?.target = self
        item.button?.action = #selector(clicked)
    }

    var anchor: CGRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
    var screen: NSScreen? { item.button?.window?.screen }
    var window: NSWindow? { item.button?.window }
    var containsPointer: Bool { anchor?.contains(NSEvent.mouseLocation) ?? false }
    func highlight(_ value: Bool) { item.button?.highlight(value) }

    @objc private func clicked() {
        LifecycleDiagnostics.statusClick()
        onToggle?()
    }

    func stop() {
        item.button?.target = nil
        onToggle = nil
        NSStatusBar.system.removeStatusItem(item)
    }
}
