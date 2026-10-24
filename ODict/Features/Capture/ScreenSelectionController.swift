import AppKit

@MainActor
protocol ScreenRegionSelecting: AnyObject {
    func select() async throws -> ScreenRegion?
    func cancel()
}

@MainActor
final class ScreenSelectionController: ScreenRegionSelecting {
    private var windows: [SelectionPanel] = []
    private var continuation: CheckedContinuation<ScreenRegion?, Error>?
    private var sessionID = UUID()
    var isSelecting: Bool { continuation != nil }

    func select() async throws -> ScreenRegion? {
        try Task.checkCancellation()
        cancel()
        let token = UUID()
        sessionID = token
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
                for screen in NSScreen.screens {
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
                    let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.isReleasedWhenClosed = false
                    panel.isOpaque = false
                    panel.backgroundColor = .clear
                    panel.hasShadow = false
                    panel.hidesOnDeactivate = false
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
                    #if DEBUG
                    panel.memory.mark("configured", width: Int(screen.frame.width * screen.backingScaleFactor),
                                      height: Int(screen.frame.height * screen.backingScaleFactor))
                    #endif
                    windows.append(panel)
                    panel.orderFrontRegardless()
                    #if DEBUG
                    panel.memory.mark("shown")
                    #endif
                }
                guard !windows.isEmpty else { finish(.failure(CaptureError.unavailable)); return }
                let point = NSEvent.mouseLocation
                (windows.first(where: { $0.frame.contains(point) }) ?? windows.first)?.makeKeyAndOrderFront(nil)
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                guard self?.sessionID == token else { return }
                self?.cancel()
            }
        })
    }

    func cancel() { finish(.success(nil)) }

    private func finish(_ result: Result<ScreenRegion?, Error>) {
        let pending = continuation
        continuation = nil
        for window in windows {
            #if DEBUG
            window.memory.mark("close.begin")
            #endif
            (window.contentView as? SelectionView)?.complete = nil
            (window.contentView as? SelectionView)?.crossDisplay = nil
            window.cancelSelection = nil
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            #if DEBUG
            window.memory.mark("close.end")
            #endif
        }
        windows.removeAll()
        NSCursor.arrow.set()
        pending?.resume(with: result)
    }
}

private final class SelectionPanel: NSPanel {
    #if DEBUG
    let memory = MemoryPhaseDiagnostics.Span("selection.window")
    deinit { memory.mark("deinit") }
    #endif
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
    private let surface = SelectionOverlaySurface()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // A layer-hosting view: no full-display draw(_:) bitmap is generated
        // when the pointer moves. The interaction view owns one fixed surface.
        layer = surface.layer
        wantsLayer = true
        updateSurface()
    }

    required init?(coder: NSCoder) { return nil }

    override func layout() {
        super.layout()
        updateSurface()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSurface()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurface()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        #if DEBUG
        (window as? SelectionPanel)?.memory.mark("drag.begin")
        #endif
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        updateSelection(.zero)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateSelection(CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y)).intersection(bounds))
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        mouseDragged(with: event)
        #if DEBUG
        (window as? SelectionPanel)?.memory.mark("drag.end")
        #endif
        start = nil
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { crossDisplay?(); return }
        guard selection.width >= 3, selection.height >= 3 else { complete?(nil); return }
        complete?(selection)
    }

    private func updateSelection(_ rect: CGRect) {
        guard rect != selection else { return }
        selection = rect
        updateSurface()
    }

    private func updateSurface() {
        surface.update(bounds: bounds, selection: selection, scale: window?.backingScaleFactor ?? 1)
    }
}

/// Four non-overlapping solid rectangles leave a transparent selection cutout.
/// Only the small, static caption has text contents; the display-sized shade has
/// no raster contents, masks, snapshots, animations or per-gesture layer growth.
@MainActor
private final class SelectionOverlaySurface {
    let layer = CALayer()
    private let shades = (0..<4).map { _ in CALayer() }
    private let outline = CALayer()
    private let hint = CALayer()
    private let caption = CATextLayer()
    private let captionSize: CGSize

    init() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: "框选单词或短语 · Escape 取消", attributes: attributes)
        captionSize = text.size()
        for shade in shades {
            shade.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
            layer.addSublayer(shade)
        }
        outline.borderColor = NSColor.white.cgColor
        outline.borderWidth = 1
        layer.addSublayer(outline)
        hint.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        hint.cornerRadius = 9
        layer.addSublayer(hint)
        caption.string = text
        hint.addSublayer(caption)
    }

    func update(bounds: CGRect, selection: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.frame = bounds
        if selection.isEmpty {
            shades[0].frame = bounds
            shades[0].isHidden = false
            for shade in shades.dropFirst() { shade.isHidden = true }
            outline.isHidden = true
        } else {
            for shade in shades { shade.isHidden = false }
            shades[0].frame = CGRect(x: bounds.minX, y: selection.maxY,
                width: bounds.width, height: max(0, bounds.maxY - selection.maxY))
            shades[1].frame = CGRect(x: bounds.minX, y: bounds.minY,
                width: bounds.width, height: max(0, selection.minY - bounds.minY))
            shades[2].frame = CGRect(x: bounds.minX, y: selection.minY,
                width: max(0, selection.minX - bounds.minX), height: selection.height)
            shades[3].frame = CGRect(x: selection.maxX, y: selection.minY,
                width: max(0, bounds.maxX - selection.maxX), height: selection.height)
            // Match the old one-point stroke entirely outside the cutout.
            outline.frame = selection.insetBy(dx: -1, dy: -1)
            outline.isHidden = false
        }
        hint.frame = CGRect(x: bounds.midX - captionSize.width / 2 - 14,
            y: bounds.maxY - 76, width: captionSize.width + 28, height: captionSize.height + 18)
        caption.frame = CGRect(origin: CGPoint(x: 14, y: 9), size: captionSize)
        caption.contentsScale = scale
    }
}
