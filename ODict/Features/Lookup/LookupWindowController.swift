import AppKit
import SwiftUI

struct LookupWindowActions {
    var openSettings: () -> Void
    var captureSelection: () -> Void
    var captureScreenshot: () -> Void
    var editQuery: () -> Void
    var interacted: () -> Void
    var dismissed: () -> Void
}

/// Owns only the native lookup window, its placement and temporary mouse monitors.
@MainActor
final class LookupWindowController {
    private let panel = LookupPanel(contentRect: CGRect(x: 0, y: 0, width: 420, height: 440),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let model: LookupModel
    private let status: MenuBarController
    private let actions: LookupWindowActions
    private var anchor: CGRect?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?

    init(model: LookupModel, status: MenuBarController, actions: LookupWindowActions) {
        self.model = model
        self.status = status
        self.actions = actions
        configure()
    }

    private(set) var isHover = false
    func contains(_ point: CGPoint) -> Bool { panel.isVisible && panel.frame.contains(point) }

    var isVisible: Bool { panel.isVisible }
    var isKeyWindow: Bool { panel.isKeyWindow }

    private func configure() {
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "ODict 查词"
        panel.acceptsMouseMovedEvents = true
        let hostingView = NSHostingView(rootView: LookupView(model: model,
            openSettings: actions.openSettings,
            close: { [weak self] in self?.hide() },
            resize: { [weak self] size in self?.resize(size) },
            captureSelection: actions.captureSelection, captureScreenshot: actions.captureScreenshot,
            editQuery: actions.editQuery))
        hostingView.autoresizingMask = [.width, .height]
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
            let origin = isHover
                ? CaptureGeometry.hoverPanelOrigin(size: panel.frame.size, anchor: anchor, visible: screen.visibleFrame)
                : CaptureGeometry.panelOrigin(size: panel.frame.size, anchor: anchor, visible: screen.visibleFrame)
            panel.setFrameOrigin(origin)
            return
        }
        guard let anchor = status.anchor else { return }
        let screen = status.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let top = min(anchor.minY - 6, visible.maxY - 6)
        let y = max(visible.minY + 8, top - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show(anchor: CGRect?, hover: Bool = false) {
        LifecycleDiagnostics.record("lookup.show.begin", panel: panel)
        self.anchor = anchor
        isHover = hover
        panel.acceptsKeyboard = !hover
        model.acceptsSearchFocus = !hover
        position()
        if hover {
            panel.makeFirstResponder(nil)
            panel.orderFrontRegardless()
        } else {
            panel.makeKeyAndOrderFront(nil)
            model.focusRequest = UUID()
        }
        status.highlight(true)
        removeMonitors()
        if !hover { installMonitors() }
        LifecycleDiagnostics.record("lookup.show.end", panel: panel)
    }

    func promote() {
        guard isHover else { return }
        isHover = false
        panel.acceptsKeyboard = true
        model.acceptsSearchFocus = true
        actions.interacted()
        panel.makeKey()
        installMonitors()
    }

    private func installMonitors() {
        removeMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.status.containsPointer else { return }
            self.hide(reason: "outsideClick")
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
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
        status.highlight(false)
        removeMonitors()
        if notifyDismissed { actions.dismissed() }
    }

    func screenChanged() { if panel.isVisible { position() } }
    private func resize(_ size: NSSize) {
        panel.setContentSize(size)
        if panel.isVisible { position() }
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
