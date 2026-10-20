import AppKit
import Carbon

/// Event driven: one monitor pair while enabled, one cancellable dwell/capture job,
/// and a short dismissal grace period. No polling, screen stream or image cache.
@MainActor
final class HoverLookupController {
    static let preferenceKey = "hoverLookupEnabled"
    static let preferenceChanged = Notification.Name("ODictHoverPreferenceChanged")
    var canBegin: () -> Bool = { true }
    var containsPanel: (CGPoint) -> Bool = { _ in false }
    var onResult: ((HoverWordHit) -> Void)?
    var onInteraction: (() -> Void)?
    var onDismiss: (() -> Void)?
    private let text: HoverTextReading
    private let image: ScreenImageCapturing
    private var ocr: ScreenTextService?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var monitoredTrust = false
    private var task: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    private var revision = UUID()
    private var pendingPoint: CGPoint?
    private var currentHit: HoverWordHit?
    private var trigger = HoverTrigger.current
    private var triggerHeld = false
    private var blockedGesture = false

    init(text: HoverTextReading = HoverTextService(), image: ScreenImageCapturing = ScreenImageService()) {
        self.text = text
        self.image = image
    }

    func updateEnabled() {
        let selected = HoverTrigger.current
        if selected != trigger {
            cancel()
            trigger = selected
            triggerHeld = false
            blockedGesture = false
        }
        guard UserDefaults.standard.bool(forKey: Self.preferenceKey) else { stop(); return }
        let trusted = CapturePermissions.accessibility
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

    func stop() {
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        globalMonitor = nil
        localMonitor = nil
        triggerHeld = false
        blockedGesture = false
        cancel()
        ocr = nil
    }

    func cancel(dismiss: Bool = true) {
        cancelCapture()
        dismissal?.cancel()
        dismissal = nil
        currentHit = nil
        if dismiss { onDismiss?() }
    }

    private func cancelCapture() {
        revision = UUID()
        task?.cancel()
        task = nil
        pendingPoint = nil
    }

    private func handle(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        let modifiers = event.modifierFlags.intersection([.control, .option, .command, .shift])
        let held = trigger.isHeld(in: modifiers)
        if !held || (trigger == .none && event.type == .mouseMoved) { blockedGesture = false }
        if held && !triggerHeld {
            blockedGesture = false
            if !containsPanel(point) { currentHit = nil; onDismiss?() }
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
        if let hit = currentHit, hit.anchor.insetBy(dx: -2, dy: -2).contains(point) {
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
        guard trigger.matches(modifiers), !blockedGesture, canBegin(), CapturePermissions.accessibility,
              !IsSecureEventInputEnabled(), NSEvent.pressedMouseButtons == 0 else {
            cancelCapture()
            dismissSoon()
            return
        }
        // Ignore tiny pointer jitter without pushing the dwell deadline forward.
        if let pendingPoint, hypot(point.x - pendingPoint.x, point.y - pendingPoint.y) <= 3 { return }
        cancelCapture()
        dismissSoon()
        pendingPoint = point
        let token = revision
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                guard let self else { return }
                defer { if self.revision == token { self.task = nil; self.pendingPoint = nil } }
                guard self.isCurrent(token, point: point),
                      let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
                      let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                var result = try await self.text.word(at: point, primaryTop: top)
                guard self.isCurrent(token, point: point) else { return }
                if result == nil, CapturePermissions.screenRecording {
                    let rect = HoverWords.region(around: point, screen: screen.frame)
                    guard HoverWords.valid(rect) else { return }
                    let region = ScreenRegion(rect: rect, displayID: display.uint32Value,
                                              screenFrame: screen.frame, scale: screen.backingScaleFactor, primaryTop: top)
                    let screenshot = try await self.image.capture(region)
                    guard self.isCurrent(token, point: point) else { return }
                    let recognizer = self.ocr ?? ScreenTextService()
                    self.ocr = recognizer
                    result = try await recognizer.recognizeWord(screenshot, region: rect, point: point)
                }
                guard self.isCurrent(token, point: point), let result else { return }
                self.dismissal?.cancel()
                self.dismissal = nil
                self.currentHit = result
                self.onResult?(result)
            } catch {
                // Missing permissions, unsupported AX, secure fields and empty OCR remain quiet.
                // In particular, secure-input failures must never fall back to OCR.
                if self?.revision == token { self?.task = nil; self?.pendingPoint = nil }
            }
        }
    }

    private func isCurrent(_ token: UUID, point: CGPoint) -> Bool {
        let flags = NSEvent.modifierFlags.intersection([.control, .option, .command, .shift])
        return !Task.isCancelled && token == revision && trigger.matches(flags) && !blockedGesture
            && canBegin() && !containsPanel(NSEvent.mouseLocation) && !IsSecureEventInputEnabled()
            && NSEvent.pressedMouseButtons == 0
            && hypot(NSEvent.mouseLocation.x - point.x, NSEvent.mouseLocation.y - point.y) <= 3
    }

    private func dismissSoon() {
        guard currentHit != nil, dismissal == nil else { return }
        dismissal = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
            guard let self else { return }
            self.dismissal = nil
            guard !self.containsPanel(NSEvent.mouseLocation),
                  self.currentHit?.anchor.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) != true else { return }
            // Dismiss the old card without cancelling a new word's in-flight capture.
            self.currentHit = nil
            self.onDismiss?()
        }
    }
}
