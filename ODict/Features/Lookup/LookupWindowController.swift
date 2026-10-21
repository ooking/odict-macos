import AppKit
import SwiftUI

struct LookupWindowActions {
    var openSettings: () -> Void
    var captureSelection: () -> Void
    var captureScreenshot: () -> Void
    var editQuery: () -> Void
    var interacted: () -> Void
    var dismissed: () -> Void
    var openAISettings: () -> Void = {}
}

/// Owns only the native lookup window, its placement and temporary mouse monitors.
@MainActor
final class LookupWindowController: NSObject, NSWindowDelegate {
    private let panel = LookupPanel(contentRect: CGRect(origin: .zero, size: LookupWindowLayout.defaultSize),
        styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
    private let model: LookupModel
    private let status: MenuBarController
    private let actions: LookupWindowActions
    private let presentation = LookupPresentation()
    private let preferences: UserDefaults
    private static let sizeKey = "lookup.windowSize.v1"
    private var userPositioned = false
    private var anchor: CGRect?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?

    init(model: LookupModel, status: MenuBarController, actions: LookupWindowActions, preferences: UserDefaults = .standard) {
        self.model = model
        self.status = status
        self.actions = actions
        self.preferences = preferences
        super.init()
        configure()
    }

    private(set) var isHover = false
    func contains(_ point: CGPoint) -> Bool { panel.isVisible && panel.frame.contains(point) }

    var isPinned: Bool { presentation.isPinned }
    var isCapture: Bool { presentation.mode == .capture }
    // Pinning keeps the card in place; it does not disable new hover lookups.
    var acceptsHoverLookup: Bool { !isVisible || isHover || (isCapture && isPinned) }

    var isVisible: Bool { panel.isVisible }
    var isKeyWindow: Bool { panel.isKeyWindow }

    private func configure() {
        panel.delegate = self
        panel.contentMinSize = LookupWindowLayout.minimumSize
        if let saved = preferences.array(forKey: Self.sizeKey) as? [Double], saved.count == 2,
           saved.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 4096 }) {
            panel.setContentSize(NSSize(width: max(saved[0], LookupWindowLayout.minimumSize.width),
                                       height: max(saved[1], LookupWindowLayout.minimumSize.height)))
        }
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "ODict 查词"
        panel.acceptsMouseMovedEvents = true
        let hostingView = NSHostingView(rootView: LookupView(model: model,
            openSettings: actions.openSettings,
            close: { [weak self] in self?.hide() },
            captureSelection: actions.captureSelection, captureScreenshot: actions.captureScreenshot,
            editQuery: actions.editQuery, openAISettings: actions.openAISettings, presentation: presentation,
            togglePin: { [weak self] in self?.togglePin() },
            dragWindow: { [weak self] event in self?.dragWindow(event) }))
        hostingView.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) { hostingView.sizingOptions = [] }
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 16
            // Clip the backing surface too: the glass shape alone does not clip
            // the borderless window's rectangular content surface at its corners.
            glass.wantsLayer = true
            glass.layer?.cornerRadius = glass.cornerRadius
            glass.layer?.masksToBounds = true
            glass.contentView = hostingView
            panel.contentView = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .followsWindowActiveState
            material.wantsLayer = true
            material.layer?.cornerRadius = 12
            material.layer?.masksToBounds = true
            hostingView.frame = material.bounds
            material.addSubview(hostingView)
            panel.contentView = material
        }
    }

    private func position() {
        if let anchor = anchor {
            let screen = NSScreen.screens.max { left, right in
                let l = left.frame.intersection(anchor), r = right.frame.intersection(anchor)
                return (l.isNull ? 0 : l.width * l.height) < (r.isNull ? 0 : r.width * r.height)
            } ?? NSScreen.main
            guard let screen else { return }
            fitToScreen(screen)
            let origin = isHover
                ? CaptureGeometry.hoverPanelOrigin(size: panel.frame.size, anchor: anchor, visible: screen.visibleFrame)
                : CaptureGeometry.panelOrigin(size: panel.frame.size, anchor: anchor, visible: screen.visibleFrame)
            panel.setFrameOrigin(origin)
            return
        }
        guard let anchor = status.anchor else { return }
        let screen = status.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        if let screen { fitToScreen(screen) }
        let size = panel.frame.size
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let top = min(anchor.minY - 6, visible.maxY - 6)
        let y = max(visible.minY + 8, top - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show(anchor: CGRect?, hover: Bool = false, mode: LookupPresentationMode = .manual) {
        let mode: LookupPresentationMode = hover ? .capture : mode
        if !panel.isVisible || presentation.mode != mode {
            presentation.isPinned = false
            userPositioned = false
        }
        presentation.mode = mode
        if mode == .manual { model.beginManual() }
        // Match native controls and WebKit's prefers-color-scheme to the white card.
        panel.appearance = mode == .capture ? NSAppearance(named: .aqua) : nil
        model.resume()
        LifecycleDiagnostics.record("lookup.show.begin", panel: panel)
        self.anchor = anchor
        isHover = hover && !isPinned
        panel.acceptsKeyboard = !isHover
        model.acceptsSearchFocus = mode == .manual
        if !userPositioned && !isPinned { position() }
        if hover {
            if !isPinned { panel.makeFirstResponder(nil) }
            panel.orderFrontRegardless()
        } else {
            panel.makeKeyAndOrderFront(nil)
            if mode == .manual { model.focusRequest = UUID() }
        }
        status.highlight(true)
        removeMonitors()
        if !isHover { installMonitors() }
        LifecycleDiagnostics.record("lookup.show.end", panel: panel)
    }

    func promote() {
        guard isHover else { return }
        isHover = false
        panel.acceptsKeyboard = true
        model.acceptsSearchFocus = presentation.mode == .manual
        actions.interacted()
        panel.makeKey()
        installMonitors()
    }

    private func installMonitors() {
        removeMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isPinned, !self.status.containsPointer else { return }
            self.hide(reason: "outsideClick")
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, !self.isPinned else { return event }
            if event.window !== self.panel && event.window !== self.status.window {
                // Native menu tracking runs its own event loop; don't dismiss its owner.
                if event.window?.level == .popUpMenu { return event }
                self.hide(reason: "localOutsideClick")
            }
            return event
        }
    }

    func hide(reason: String = "requested", notifyDismissed: Bool = true) {
        LifecycleDiagnostics.record("lookup.hide.\(reason)", panel: panel)
        panel.orderOut(nil)
        isHover = false
        presentation.isPinned = false
        userPositioned = false
        status.highlight(false)
        removeMonitors()
        if notifyDismissed { actions.dismissed() }
    }

    private func togglePin() {
        promote()
        presentation.isPinned.toggle()
    }

    private func dragWindow(_ event: NSEvent) {
        promote()
        userPositioned = true
        panel.performDrag(with: event)
    }

    private func constrainToScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: max(visible.minX, min(frame.minX, visible.maxX - frame.width)),
            y: max(visible.minY, min(frame.minY, visible.maxY - frame.height))))
    }

    func screenChanged() {
        guard panel.isVisible else { return }
        if let screen = panel.screen { fitToScreen(screen) }
        if userPositioned || isPinned { constrainToScreen() } else { position() }
    }
    // Native live resizing drives the flexible hosting view directly; no per-frame published state.
    func windowWillStartLiveResize(_ notification: Notification) {
        promote()
        userPositioned = true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        constrainToScreen()
        preferences.set([panel.frame.width, panel.frame.height], forKey: Self.sizeKey)
    }

    private func fitToScreen(_ screen: NSScreen) {
        let available = screen.visibleFrame.insetBy(dx: 8, dy: 8).size
        panel.contentMaxSize = NSSize(width: max(LookupWindowLayout.minimumSize.width, available.width),
                                     height: max(LookupWindowLayout.minimumSize.height, available.height))
        let size = NSSize(width: min(panel.frame.width, panel.contentMaxSize.width),
                          height: min(panel.frame.height, panel.contentMaxSize.height))
        if size != panel.frame.size { panel.setContentSize(size) }
    }
    private func removeMonitors() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
    }
}

private final class LookupPanel: NSPanel {
    var acceptsKeyboard = true
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}
