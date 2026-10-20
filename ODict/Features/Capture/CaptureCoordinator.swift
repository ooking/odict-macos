import AppKit

@MainActor
final class CaptureCoordinator {
    private let selectedText: SelectedTextReading
    private let accessibilityAllowed: () -> Bool
    private let screenAllowed: () -> Bool
    private let requestAccessibility: () -> Void
    private let requestScreen: () -> Void
    private let screenText = ScreenTextService()
    private let selection = ScreenSelectionController()
    private var task: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var revision = UUID()
    var isSelecting: Bool { selection.isSelecting }
    var onResult: ((CapturedText) -> Void)?
    var onFailure: ((String, CGRect) -> Void)?
    var onRecognizing: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    init(selectedText: SelectedTextReading = SelectedTextService(),
         accessibilityAllowed: @escaping () -> Bool = { CapturePermissions.accessibility },
         screenAllowed: @escaping () -> Bool = { CapturePermissions.screenRecording },
         requestAccessibility: @escaping () -> Void = { CapturePermissions.requestAccessibility() },
         requestScreen: @escaping () -> Void = { _ = CGRequestScreenCaptureAccess() }) {
        self.selectedText = selectedText
        self.accessibilityAllowed = accessibilityAllowed
        self.screenAllowed = screenAllowed
        self.requestAccessibility = requestAccessibility
        self.requestScreen = requestScreen
    }

    func cancel() {
        revision = UUID()
        task?.cancel()
        task = nil
        selection.cancel()
        removeEscapeMonitor()
    }

    func takeSelection(pid: pid_t?, anchor: CGRect, primaryTop: CGFloat) {
        cancel()
        guard accessibilityAllowed() else {
            requestAccessibility()
            onFailure?(CaptureError.accessibilityPermission.localizedDescription, anchor)
            return
        }
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else {
            onFailure?(CaptureError.noSelection.localizedDescription, anchor)
            return
        }
        let token = revision
        task = Task { [weak self, selectedText] in
            defer { if self?.revision == token { self?.task = nil } }
            do {
                let result = try await selectedText.read(pid: pid, fallbackAnchor: anchor, primaryTop: primaryTop)
                guard !Task.isCancelled, self?.revision == token else { return }
                self?.onResult?(result)
            } catch {
                guard !Task.isCancelled, self?.revision == token else { return }
                self?.onFailure?(error.localizedDescription, anchor)
            }
        }
    }

    func takeScreenshot(anchor: CGRect) {
        cancel()
        guard screenAllowed() else {
            requestScreen()
            onFailure?(CaptureError.screenPermission.localizedDescription, anchor)
            return
        }
        let token = revision
        // Also handle Escape between removing the overlay and receiving the screenshot.
        // This listener exists only for the current screenshot operation, with no global key tap.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancel()
            self?.onCancelled?()
            return nil
        }
        task = Task { [weak self, selection, screenText] in
            defer {
                if self?.revision == token {
                    self?.task = nil
                    self?.removeEscapeMonitor()
                }
            }
            var resultAnchor = anchor
            do {
                try Task.checkCancellation()
                guard self?.revision == token else { return }
                guard let region = try await selection.select() else {
                    if !Task.isCancelled, self?.revision == token { self?.onCancelled?() }
                    return
                }
                try Task.checkCancellation()
                resultAnchor = region.rect
                let text: String
                do {
                    // Limit image lifetime to recognition; only text survives into lookup.
                    let image = try await ScreenImageService.capture(region)
                    guard !Task.isCancelled, self?.revision == token else { return }
                    self?.onRecognizing?(region.rect)
                    text = try await screenText.recognize(image)
                }
                guard !Task.isCancelled, self?.revision == token else { return }
                self?.onResult?(CapturedText(text: text, source: .screenshot, anchor: region.rect))
            } catch {
                guard !Task.isCancelled, self?.revision == token else { return }
                let message = (error as? CaptureError)?.localizedDescription ?? CaptureError.unavailable.localizedDescription
                self?.onFailure?(message, resultAnchor)
            }
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor { NSEvent.removeMonitor(monitor) }
        escapeMonitor = nil
    }
}
