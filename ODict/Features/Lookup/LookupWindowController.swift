import AppKit
import SwiftUI

struct LookupWindowActions {
    var openSettings: () -> Void
    var captureSelection: () -> Void
    var captureScreenshot: () -> Void
    var editQuery: () -> Void
    var interacted: () -> Void
    var dismissed: (_ restoresSourceFocus: Bool) -> Void
    var openAISettings: () -> Void = {}
    var openSetup: (SettingsCategory) -> Void = { _ in }
}

/// Owns window placement, bounded content sizing and visible-session event monitors.
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
    private static let captureHeightKey = "lookup.capture.manualHeight"
    private var captureManualHeight = LookupWindowLayout.defaultSize.height
    private var normalSize = LookupWindowLayout.defaultSize
    private var measuredContentHeight: CGFloat?
    private var pendingHeightUpdate: DispatchWorkItem?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var userPositioned = false
    private var anchor: CGRect?
    private var pinnedCaptureOrigin: CGPoint?

    init(model: LookupModel, status: MenuBarController, actions: LookupWindowActions, preferences: UserDefaults = .standard) {
        self.model = model
        self.status = status
        self.actions = actions
        self.preferences = preferences
        super.init()
        configure()
        NotificationCenter.default.addObserver(self, selector: #selector(captureSettingsChanged),
            name: CaptureWindowSettings.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(captureWidthChanged),
            name: CaptureWindowSettings.widthChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(captureAppearanceChanged),
            name: CaptureWindowSettings.appearanceChanged, object: nil)
    }

    private(set) var isHover = false
    func contains(_ point: CGPoint) -> Bool { panel.isVisible && panel.frame.contains(point) }

    var isCapture: Bool { presentation.mode == .capture }
    // A persistent capture window can still receive subsequent hover results.
    var acceptsHoverLookup: Bool { !isVisible || isCapture }

    var isVisible: Bool { panel.isVisible }

    /// An ordered-in window may still be behind another app or on another Space.
    /// Nonactivating floating panels can own keyboard focus without activating ODict.
    var isPresentedForInteraction: Bool {
        panel.isVisible && panel.isKeyWindow && panel.isOnActiveSpace
            && panel.occlusionState.contains(.visible)
            && (panel.isFloatingPanel || NSApp.isActive)
    }

    /// Restore an existing manual session without resetting its query or AI override.
    func showManual() {
        guard panel.isVisible, !isCapture else {
            show(anchor: nil)
            return
        }
        focusManualWindow()
    }

    private func focusManualWindow() {
        // Settings shares the normal window level with lookup. Activate the app
        // before ordering lookup so it can come forward from behind another app.
        if !panel.isFloatingPanel { NSApp.activate(ignoringOtherApps: true) }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        model.focusRequest = UUID()
    }

    /// Settings uses a normal window. While it is open, use the same level so
    /// ordinary click/activation ordering works without hiding either window.
    func setSettingsPresented(_ presented: Bool) {
        panel.isFloatingPanel = !presented
        panel.level = presented ? .normal : .floating
    }

    private func configure() {
        panel.delegate = self
        panel.onInteraction = { [weak self] in self?.promote() }
        panel.contentMinSize = LookupWindowLayout.minimumSize
        if let saved = preferences.array(forKey: Self.sizeKey) as? [Double], saved.count == 2,
           saved.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 4096 }) {
            panel.setContentSize(NSSize(width: max(saved[0], LookupWindowLayout.minimumSize.width),
                                       height: max(saved[1], LookupWindowLayout.minimumSize.height)))
        }
        normalSize = panel.frame.size
        let savedCaptureHeight = preferences.object(forKey: Self.captureHeightKey) as? Double ?? Double(normalSize.height)
        if savedCaptureHeight.isFinite {
            captureManualHeight = CGFloat(min(max(savedCaptureHeight, Double(LookupWindowLayout.minimumSize.height)), 4096))
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
            dragWindow: { [weak self] event in self?.dragWindow(event) },
            togglePin: { [weak self] in self?.togglePin() }, openSetup: actions.openSetup,
            contentHeightChanged: { [weak self] height in self?.contentHeightChanged(height) }))
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
        let updatingHover = hover && panel.isVisible && presentation.mode == .capture
        let startsSession = !panel.isVisible || presentation.mode != mode
        if startsSession {
            userPositioned = false
        }
        if presentation.mode != mode {
            measuredContentHeight = nil
            presentation.mode = mode
        }
        updateHeightPolicy(restoresSize: startsSession)
        captureAppearanceChanged()
        if mode == .manual { model.beginManual() }
        // Match native controls and WebKit's prefers-color-scheme to the white card.
        panel.appearance = mode == .capture ? NSAppearance(named: .aqua) : nil
        model.resume()
        LifecycleDiagnostics.record("lookup.show.begin", panel: panel)
        self.anchor = mode == .capture
            ? CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 1))
            : anchor
        isHover = hover && !panel.isKeyWindow
        panel.acceptsKeyboard = !isHover
        let acceptsSearchFocus = mode == .manual
        if model.acceptsSearchFocus != acceptsSearchFocus { model.acceptsSearchFocus = acceptsSearchFocus }
        if mode == .capture {
            if presentation.isPinned, let origin = pinnedCaptureOrigin {
                panel.setFrameOrigin(origin)
                if let screen = NSScreen.screens.first(where: { $0.frame.contains(origin) }) {
                    fitToScreen(screen)
                }
                constrainToScreen()
                pinnedCaptureOrigin = panel.frame.origin
            } else {
                // Dragging alone does not pin: every new capture follows the pointer.
                userPositioned = false
                position()
            }
        } else if !userPositioned {
            position()
        }
        if hover {
            if isHover { panel.makeFirstResponder(nil) }
            panel.orderFrontRegardless()
        } else if mode == .manual {
            focusManualWindow()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        updateClickMonitors()
        if presentation.fitsContentHeight { scheduleHeightUpdate() }
        status.highlight(true)
        LifecycleDiagnostics.record(updatingHover ? "lookup.hoverUpdated" : "lookup.show.end", panel: panel)
    }

    func promote() {
        guard isHover else { return }
        isHover = false
        panel.acceptsKeyboard = true
        model.acceptsSearchFocus = presentation.mode == .manual
        actions.interacted()
        panel.makeKey()
    }

    func hide(restoringSourceFocus: Bool = true) {
        LifecycleDiagnostics.record("lookup.hide.requested", panel: panel)
        stopClickMonitors()
        pendingHeightUpdate?.cancel()
        pendingHeightUpdate = nil
        measuredContentHeight = nil
        model.acceptsSearchFocus = false
        panel.endEditing(for: nil)
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        isHover = false
        userPositioned = false
        status.highlight(false)
        actions.dismissed(restoringSourceFocus)
    }

    private func togglePin() {
        presentation.isPinned.toggle()
        pinnedCaptureOrigin = presentation.isPinned ? panel.frame.origin : nil
    }

    private func dragWindow(_ event: NSEvent) {
        promote()
        userPositioned = true
        panel.performDrag(with: event)
        if isCapture && presentation.isPinned { pinnedCaptureOrigin = panel.frame.origin }
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
        if presentation.fitsContentHeight { scheduleHeightUpdate() }
        if userPositioned || (isCapture && presentation.isPinned) {
            constrainToScreen()
            if isCapture && presentation.isPinned { pinnedCaptureOrigin = panel.frame.origin }
        } else { position() }
    }
    // Native live resizing drives the flexible hosting view directly; no per-frame published state.
    func windowWillStartLiveResize(_ notification: Notification) {
        promote()
        userPositioned = true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        constrainToScreen()
        if isCapture && presentation.isPinned { pinnedCaptureOrigin = panel.frame.origin }
        if isCapture {
            if !presentation.fitsContentHeight {
                captureManualHeight = panel.frame.height
                preferences.set(captureManualHeight, forKey: Self.captureHeightKey)
            }
        } else {
            normalSize = panel.frame.size
            preferences.set([normalSize.width, normalSize.height], forKey: Self.sizeKey)
        }
        if presentation.fitsContentHeight { scheduleHeightUpdate() }
    }

    @objc private func captureSettingsChanged() {
        updateHeightPolicy()
        updateClickMonitors()
        if presentation.fitsContentHeight { scheduleHeightUpdate() }
    }

    @objc private func captureAppearanceChanged() {
        panel.alphaValue = isCapture ? CaptureWindowSettings.alpha(in: preferences) : 1
    }

    @objc private func captureWidthChanged() {
        guard isCapture, panel.isVisible else { return }
        setSizePreservingTop(NSSize(width: CaptureWindowSettings.width(in: preferences), height: panel.frame.height))
        if presentation.fitsContentHeight { scheduleHeightUpdate() }
    }

    private func setSizePreservingTop(_ size: NSSize) {
        let top = panel.frame.maxY
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
        if let screen = panel.screen { fitToScreen(screen) }
        constrainToScreen()
        if isCapture && presentation.isPinned { pinnedCaptureOrigin = panel.frame.origin }
    }

    private func updateHeightPolicy(restoresSize: Bool = false) {
        let enabled = isCapture && preferences.bool(forKey: CaptureWindowSettings.fitsContentHeightKey)
        let changed = presentation.fitsContentHeight != enabled
        if changed { presentation.fitsContentHeight = enabled }
        panel.contentMinSize = NSSize(width: LookupWindowLayout.minimumSize.width,
            height: enabled ? LookupWindowLayout.minimumCaptureHeight : LookupWindowLayout.minimumSize.height)
        if !enabled {
            pendingHeightUpdate?.cancel()
            pendingHeightUpdate = nil
            if changed || restoresSize {
                let size = isCapture
                    ? NSSize(width: restoresSize ? CaptureWindowSettings.width(in: preferences) : panel.frame.width,
                             height: captureManualHeight)
                    : normalSize
                setSizePreservingTop(size)
            }
        } else if restoresSize {
            setSizePreservingTop(NSSize(width: CaptureWindowSettings.width(in: preferences), height: panel.frame.height))
        }
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard height.isFinite, height > 0, presentation.fitsContentHeight else { return }
        measuredContentHeight = min(height, 100_000)
        scheduleHeightUpdate()
    }

    private func scheduleHeightUpdate() {
        guard panel.isVisible, presentation.fitsContentHeight, pendingHeightUpdate == nil else { return }
        // Coalesce streaming/layout updates; retain at most one small pending item.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingHeightUpdate = nil
            self.resizeToContent()
        }
        pendingHeightUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func resizeToContent() {
        guard panel.isVisible, presentation.fitsContentHeight, !panel.inLiveResize,
              let height = measuredContentHeight, let screen = panel.screen ?? NSScreen.main else { return }
        let available = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let maximumHeight = min(CaptureWindowSettings.maximumHeight(in: preferences), available.height)
        let target = min(max(ceil(height), LookupWindowLayout.minimumCaptureHeight), maximumHeight)
        guard abs(panel.frame.height - target) >= 1 else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - target
        frame.size.height = target
        frame.origin.y = max(available.minY, min(frame.minY, available.maxY - target))
        panel.setFrame(frame, display: true)
        if presentation.isPinned { pinnedCaptureOrigin = panel.frame.origin }
    }

    private func updateClickMonitors() {
        let enabled = panel.isVisible && isCapture
            && preferences.bool(forKey: CaptureWindowSettings.closesOnOutsideClickKey)
        guard enabled else { stopClickMonitors(); return }
        guard localClickMonitor == nil, globalClickMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleOutsideClick(event)
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleOutsideClick(event)
        }
    }

    private func handleOutsideClick(_ event: NSEvent) {
        guard panel.isVisible, isCapture, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        // Native menus and child windows belong to the current interaction.
        if let window = event.window {
            if window.level >= .popUpMenu { return }
            var parent: NSWindow? = window
            while let current = parent {
                if current === panel { return }
                parent = current.parent
            }
        }
        hide(restoringSourceFocus: false)
    }

    private func stopClickMonitors() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
    }

    deinit {
        pendingHeightUpdate?.cancel()
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    private func fitToScreen(_ screen: NSScreen) {
        let available = screen.visibleFrame.insetBy(dx: 8, dy: 8).size
        panel.contentMaxSize = NSSize(width: max(LookupWindowLayout.minimumSize.width, available.width),
                                     height: max(panel.contentMinSize.height, available.height))
        let size = NSSize(width: min(panel.frame.width, panel.contentMaxSize.width),
                          height: min(panel.frame.height, panel.contentMaxSize.height))
        if size != panel.frame.size { panel.setContentSize(size) }
    }

}

private final class LookupPanel: NSPanel {
    var acceptsKeyboard = true
    var onInteraction: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { onInteraction?() }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}
