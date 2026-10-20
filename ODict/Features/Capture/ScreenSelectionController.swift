import AppKit

@MainActor
final class ScreenSelectionController {
    private var windows: [SelectionPanel] = []
    private var continuation: CheckedContinuation<ScreenRegion?, Error>?
    var isSelecting: Bool { continuation != nil }

    func select() async throws -> ScreenRegion? {
        try Task.checkCancellation()
        cancel()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            for screen in NSScreen.screens {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
                let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.level = .screenSaver
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.isMovable = false
                panel.setAccessibilityLabel("框选需要查询的单词或短语，按 Escape 取消")
                let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
                view.complete = { [weak self] rect in
                    guard let self else { return }
                    guard let rect else { self.cancel(); return }
                    let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                    let region = ScreenRegion(rect: global, displayID: number.uint32Value,
                        screenFrame: screen.frame, scale: screen.backingScaleFactor, primaryTop: primaryTop)
                    self.finish(.success(region))
                }
                view.crossDisplay = { [weak self] in self?.finish(.failure(CaptureError.crossDisplay)) }
                panel.cancelSelection = { [weak self] in self?.cancel() }
                panel.contentView = view
                windows.append(panel)
                panel.orderFrontRegardless()
            }
            guard !windows.isEmpty else { finish(.failure(CaptureError.unavailable)); return }
            NSApp.activate(ignoringOtherApps: true)
            let point = NSEvent.mouseLocation
            (windows.first(where: { $0.frame.contains(point) }) ?? windows.first)?.makeKeyAndOrderFront(nil)
        }
    }

    func cancel() { finish(.success(nil)) }

    private func finish(_ result: Result<ScreenRegion?, Error>) {
        let pending = continuation
        continuation = nil
        for window in windows {
            (window.contentView as? SelectionView)?.complete = nil
            (window.contentView as? SelectionView)?.crossDisplay = nil
            window.cancelSelection = nil
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        NSCursor.arrow.set()
        pending?.resume(with: result)
    }
}

private final class SelectionPanel: NSPanel {
    var cancelSelection: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelSelection?() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { cancelSelection?() }
}

private final class SelectionView: NSView {
    var complete: ((CGRect?) -> Void)?
    var crossDisplay: (() -> Void)?
    private var start: CGPoint?
    private var selection = CGRect.zero
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y)).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        mouseDragged(with: event)
        start = nil
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { crossDisplay?(); return }
        guard selection.width >= 3, selection.height >= 3 else { complete?(nil); return }
        complete?(selection)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        if !selection.isEmpty { shade.append(NSBezierPath(rect: selection)) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.22).setFill()
        shade.fill()
        if !selection.isEmpty {
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
            outline.lineWidth = 1
            outline.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white
        ]
        let label = "框选单词或短语 · Escape 取消"
        let size = label.size(withAttributes: attributes)
        let rect = CGRect(x: (bounds.width - size.width) / 2 - 14, y: bounds.height - 76,
            width: size.width + 28, height: size.height + 18)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        label.draw(at: CGPoint(x: rect.minX + 14, y: rect.minY + 9), withAttributes: attributes)
    }
}
