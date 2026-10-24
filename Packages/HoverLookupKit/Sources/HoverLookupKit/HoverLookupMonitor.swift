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
    private var pressedKeys: Set<UInt16> = []
    private var lastBlockReason: HoverDiagnostic.Reason?

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
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .mouseMoved, .keyDown, .keyUp, .leftMouseDown,
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
        pressedKeys.removeAll()
        lastBlockReason = nil
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

    /// Host window interactions have ended. Retire old responses and gesture
    /// state, but wait for a new event instead of querying immediately on close.
    public func resetInteraction() {
        cancel(dismiss: false)
        triggerHeld = false
        blockedGesture = false
        pressedKeys.removeAll()
        lastBlockReason = nil
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

        if event.type == .keyUp {
            pressedKeys.remove(event.keyCode)
            return
        }
        if event.type == .mouseMoved {
            // Recover even if another app consumed a key-up event. Read only
            // physical state for keys observed during this gesture, never text.
            pressedKeys = pressedKeys.filter { CGEventSource.keyState(.combinedSessionState, key: $0) }
            blockedGesture = !pressedKeys.isEmpty || NSEvent.pressedMouseButtons != 0
        }
        if event.type == .keyDown {
            pressedKeys.insert(event.keyCode)
            blockedGesture = true
            currentAnchor = nil
            reportBlock(.interaction)
            cancelCapture()
            if event.keyCode == 53 || !containsPanel(point) { cancel() }
            return
        }
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            blockedGesture = true
            currentAnchor = nil
            reportBlock(.interaction)
            cancelCapture()
            if containsPanel(point) { onInteraction?() } else { cancel() }
            return
        }
        if event.type == .scrollWheel {
            blockedGesture = true
            currentAnchor = nil
            reportBlock(.interaction)
            cancelCapture()
            if !containsPanel(point) { cancel() }
            return
        }
        if containsPanel(point) {
            reportBlock(.ownWindow)
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
        let reason: HoverDiagnostic.Reason?
        if !trigger.matches(modifiers) { reason = .modifier }
        else if blockedGesture || !pressedKeys.isEmpty || NSEvent.pressedMouseButtons != 0 { reason = .interaction }
        else if !canBegin() { reason = .hostBusy }
        else { reason = nil }
        if let reason {
            reportBlock(reason)
            cancelCapture()
            dismissSoon()
            return
        }
        lastBlockReason = nil
        // Ignore tiny pointer jitter without pushing the dwell deadline forward.
        if let pendingPoint, stability.accepts(origin: pendingPoint, current: point, extracting: extracting) { return }
        cancelCapture()
        dismissSoon()
        pendingPoint = point
        let token = revision
        let started = ProcessInfo.processInfo.systemUptime
        task = Task { [weak self] in
            defer {
                if let self, self.revision == token {
                    self.task = nil; self.pendingPoint = nil; self.extracting = false
                }
            }
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                guard let self else { return }
                guard self.isCurrent(token, point: point, allowsSecureFailure: true) else { return }
                guard AXIsProcessTrusted() else { throw HoverLookupError.accessibilityPermission }
                guard !IsSecureEventInputEnabled() else { throw HoverLookupError.secureInput }
                guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
                      let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { throw HoverLookupError.captureFailed }
                self.extracting = true
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                let rect = HoverWords.region(around: point, screen: screen.frame)
                guard HoverWords.valid(rect) else { throw HoverLookupError.captureFailed }
                let region = ScreenRegion(rect: rect, displayID: display.uint32Value,
                    screenFrame: screen.frame, scale: screen.backingScaleFactor, primaryTop: top)
                let result = try await self.pipeline.word(in: region, at: point, allowsOCR: CGPreflightScreenCaptureAccess())
                guard self.isCurrent(token, point: point) else { return }
                guard let result else { throw HoverLookupError.noText }
                guard self.stability.accepts(result, at: NSEvent.mouseLocation) else {
                    self.onDiagnostic?(HoverDiagnostic(.request, .miss, since: ProcessInfo.processInfo.systemUptime))
                    throw HoverLookupError.noText
                }
                self.dismissal?.cancel()
                self.dismissal = nil
                self.currentAnchor = result.anchor
                self.onResult?(result)
                self.onDiagnostic?(HoverDiagnostic(.request, .hit, since: started))
            } catch {
                guard !(error is CancellationError), let self,
                      self.isCurrent(token, point: point, allowsSecureFailure: true) else { return }
                let failure: HoverLookupError
                if let ocr = error as? OCRFailure { failure = .ocrFailure(ocr) }
                else if error is FallbackTargetRejection { failure = .fallbackTargetUnavailable }
                else { failure = (error as? HoverLookupError) ?? .recognitionFailed }
                self.dismissal?.cancel()
                self.dismissal = nil
                let anchor = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
                self.currentAnchor = anchor
                let reason: HoverDiagnostic.Reason?
                switch failure {
                case .ocrFailure(let ocr):
                    reason = ocr.kind == .modelResourcesUnavailable ? .ocrModelResources : .ocrEngine
                case .secureInput: reason = .secureInput
                case .accessibilityPermission, .screenPermission: reason = .permission
                case .fallbackTargetUnavailable: reason = .fallbackTarget
                case .requestBusy: reason = .providerBusy
                case .securityInspectionFailed, .securityDepthExceeded: reason = .safetyCheck
                default: reason = nil
                }
                self.onDiagnostic?(HoverDiagnostic(.request, .failed, since: started, reason: reason))
                self.onFailure?(failure, anchor)
            }
        }
    }

    private func reportBlock(_ reason: HoverDiagnostic.Reason) {
        guard reason != lastBlockReason else { return }
        lastBlockReason = reason
        onDiagnostic?(HoverDiagnostic(.request, .blocked,
            since: ProcessInfo.processInfo.systemUptime, reason: reason))
    }

    private func isCurrent(_ token: UUID, point: CGPoint, allowsSecureFailure: Bool = false) -> Bool {
        let flags = NSEvent.modifierFlags.intersection([.control, .option, .command, .shift])
        return !Task.isCancelled && token == revision && trigger.matches(flags) && !blockedGesture
            && pressedKeys.isEmpty && canBegin() && !containsPanel(NSEvent.mouseLocation)
            && (allowsSecureFailure || !IsSecureEventInputEnabled())
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
