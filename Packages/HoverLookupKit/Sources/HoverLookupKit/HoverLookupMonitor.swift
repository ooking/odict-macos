import AppKit
import Carbon
import ApplicationServices

/// Event driven: one monitor pair while enabled, one cancellable dwell/capture job,
/// and a short dismissal grace period. No polling, screen stream or image cache.
@MainActor
public final class HoverLookupMonitor {
    public var canBegin: () -> Bool = { true }
    public var containsPanel: (CGPoint) -> Bool = { _ in false }
    public var onResult: ((HoverWordHit) -> Void)?
    public var onFailure: ((HoverLookupError, CGRect) -> Void)?
    public var onInteraction: (() -> Void)?
    public var onDismiss: (() -> Void)?
    public var onDiagnostic: ((HoverDiagnostic) -> Void)? {
        didSet { pipeline.onDiagnostic = onDiagnostic }
    }
    public var stability = HoverStability()
    private let pipeline: HoverLookupPipeline
    private var extracting = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var monitoredTrust = false
    private var task: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    private var revision = UUID()
    private var pendingPoint: CGPoint?
    private var currentAnchor: CGRect?
    private var trigger = HoverModifier.control
    private var triggerHeld = false
    private var blockedGesture = false

    public init(pipeline: HoverLookupPipeline? = nil) { self.pipeline = pipeline ?? HoverLookupPipeline() }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        task?.cancel()
        dismissal?.cancel()
    }

    /// Call after preference/permission changes and when the host becomes active.
    /// Does not request permissions or open system settings.
    public func setEnabled(_ enabled: Bool, modifier selected: HoverModifier = .control) {
        if selected != trigger {
            cancel()
            trigger = selected
            triggerHeld = false
            blockedGesture = false
        }
        guard enabled else { stop(); return }
        let trusted = AXIsProcessTrusted()
        guard trusted else { stop(); return }
        if globalMonitor != nil || localMonitor != nil {
            if monitoredTrust == trusted { return }
            stop()
        }
        monitoredTrust = trusted
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .mouseMoved, .keyDown, .leftMouseDown,
                                           .rightMouseDown, .otherMouseDown, .scrollWheel]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.handle(event) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    public func stop() {
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        globalMonitor = nil
        localMonitor = nil
        triggerHeld = false
        blockedGesture = false
        cancel()
        pipeline.releaseResources()
    }

    public func cancel(dismiss: Bool = true) {
        cancelCapture()
        dismissal?.cancel()
        dismissal = nil
        currentAnchor = nil
        pipeline.releaseResources()
        if dismiss { onDismiss?() }
    }

    private func cancelCapture() {
        revision = UUID()
        task?.cancel()
        task = nil
        pendingPoint = nil
        extracting = false
    }

    private func handle(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        let modifiers = event.modifierFlags.intersection([.control, .option, .command, .shift])
        let held = trigger.isHeld(in: modifiers)
        if !held || (trigger == .none && event.type == .mouseMoved) { blockedGesture = false }
        if held && !triggerHeld {
            blockedGesture = false
            if !containsPanel(point) { currentAnchor = nil; onDismiss?() }
        }
        triggerHeld = held

        if event.type == .keyDown {
            blockedGesture = true
            cancelCapture()
            if event.keyCode == 53 || !containsPanel(point) { cancel() }
            return
        }
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            blockedGesture = true
            cancelCapture()
            if containsPanel(point) { onInteraction?() } else { cancel() }
            return
        }
        if event.type == .scrollWheel {
            blockedGesture = true
            cancelCapture()
            if !containsPanel(point) { cancel() }
            return
        }
        if containsPanel(point) {
            cancelCapture()
            dismissal?.cancel()
            dismissal = nil
            return
        }
        if let anchor = currentAnchor, anchor.insetBy(dx: -2, dy: -2).contains(point) {
            cancelCapture()
            dismissal?.cancel()
            dismissal = nil
            return
        }
        // Unmodified hover re-arms only on mouse movement, never after typing
        // or releasing a keyboard shortcut while the pointer stays stationary.
        if trigger == .none && event.type != .mouseMoved {
            cancelCapture()
            return
        }
        guard trigger.matches(modifiers), !blockedGesture, canBegin(), AXIsProcessTrusted(),
              !IsSecureEventInputEnabled(), NSEvent.pressedMouseButtons == 0 else {
            cancelCapture()
            dismissSoon()
            return
        }
        // Ignore tiny pointer jitter without pushing the dwell deadline forward.
        if let pendingPoint, stability.accepts(origin: pendingPoint, current: point, extracting: extracting) { return }
        cancelCapture()
        dismissSoon()
        pendingPoint = point
        let token = revision
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                guard let self else { return }
                defer {
                    if self.revision == token { self.task = nil; self.pendingPoint = nil; self.extracting = false }
                }
                guard self.isCurrent(token, point: point),
                      let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
                      let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
                self.extracting = true
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                let rect = HoverWords.region(around: point, screen: screen.frame)
                guard HoverWords.valid(rect) else { return }
                let region = ScreenRegion(rect: rect, displayID: display.uint32Value,
                    screenFrame: screen.frame, scale: screen.backingScaleFactor, primaryTop: top)
                let result = try await self.pipeline.word(in: region, at: point, allowsOCR: CGPreflightScreenCaptureAccess())
                guard self.isCurrent(token, point: point), let result else { return }
                guard self.stability.accepts(result, at: NSEvent.mouseLocation) else {
                    self.onDiagnostic?(HoverDiagnostic(.request, .miss, since: ProcessInfo.processInfo.systemUptime))
                    return
                }
                self.dismissal?.cancel()
                self.dismissal = nil
                self.currentAnchor = result.anchor
                self.onResult?(result)
            } catch {
                guard let self, self.isCurrent(token, point: point) else { return }
                // Cancellation, own windows, secure/unknown targets and whitespace
                // stay quiet. Real capture/recognition/permission failures are actionable.
                guard let failure = error as? HoverLookupError else { return }
                switch failure {
                case .captureFailed, .recognitionFailed, .screenPermission:
                    self.dismissal?.cancel()
                    self.dismissal = nil
                    let anchor = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
                    self.currentAnchor = anchor
                    self.onFailure?(failure, anchor)
                default: break
                }
            }
        }
    }

    private func isCurrent(_ token: UUID, point: CGPoint) -> Bool {
        let flags = NSEvent.modifierFlags.intersection([.control, .option, .command, .shift])
        return !Task.isCancelled && token == revision && trigger.matches(flags) && !blockedGesture
            && canBegin() && !containsPanel(NSEvent.mouseLocation) && !IsSecureEventInputEnabled()
            && NSEvent.pressedMouseButtons == 0
            && stability.accepts(origin: point, current: NSEvent.mouseLocation, extracting: extracting)
    }

    private func dismissSoon() {
        guard currentAnchor != nil, dismissal == nil else { return }
        dismissal = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
            guard let self else { return }
            self.dismissal = nil
            guard !self.containsPanel(NSEvent.mouseLocation),
                  self.currentAnchor?.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) != true else { return }
            // Dismiss the old card without cancelling a new word's in-flight capture.
            self.currentAnchor = nil
            self.pipeline.releaseResources()
            self.onDismiss?()
        }
    }
}
