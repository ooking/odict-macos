import AppKit

@MainActor
final class CaptureCoordinator {
    enum Phase { case idle, readingSelection, selectingRegion, capturingImage, recognizingText }
    private(set) var phase: Phase = .idle
    var isRunning: Bool { task != nil }
    private let selectedText: SelectedTextReading
    private let accessibilityAllowed: () -> Bool
    private let screenAllowed: () -> Bool
    private let requestAccessibility: () -> Void
    private let requestScreen: () -> Void
    private let screenText: ScreenTextRecognizing
    private let screenImage: ScreenImageCapturing
    private let selection: ScreenRegionSelecting
    private var task: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var revision = UUID()
    var isSelecting: Bool { phase == .selectingRegion }
    var onResult: ((CapturedText) -> Void)?
    var onFailure: ((String, CGRect) -> Void)?
    var onRecognizing: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    init(selectedText: SelectedTextReading = SelectedTextService(),
         accessibilityAllowed: @escaping () -> Bool = { CapturePermissions.accessibility },
         screenAllowed: @escaping () -> Bool = { CapturePermissions.screenRecording },
         requestAccessibility: @escaping () -> Void = { CapturePermissions.requestAccessibility() },
         requestScreen: @escaping () -> Void = { CapturePermissions.requestScreenRecording() },
         selection: ScreenRegionSelecting? = nil,
         screenImage: ScreenImageCapturing = ScreenImageService(),
         screenText: ScreenTextRecognizing = ScreenTextService()) {
        self.selectedText = selectedText
        self.accessibilityAllowed = accessibilityAllowed
        self.screenAllowed = screenAllowed
        self.requestAccessibility = requestAccessibility
        self.requestScreen = requestScreen
        self.selection = selection ?? ScreenSelectionController()
        self.screenImage = screenImage
        self.screenText = screenText
    }

    func cancel() {
        revision = UUID()
        phase = .idle
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
        phase = .readingSelection
        task = Task { [weak self, selectedText] in
            defer { if self?.revision == token { self?.task = nil; self?.phase = .idle } }
            do {
                try Task.checkCancellation()
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
        phase = .selectingRegion
        // Also handle Escape between removing the overlay and receiving the screenshot.
        // This listener exists only for the current screenshot operation, with no global key tap.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancel()
            self?.onCancelled?()
            return nil
        }
        task = Task { [weak self, selection, screenText, screenImage] in
            defer {
                if self?.revision == token {
                    self?.task = nil
                    self?.phase = .idle
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
                self?.phase = .capturingImage
                let text: String
                do {
                    // Limit image lifetime to recognition; only text survives into lookup.
                    let image = try await screenImage.capture(region)
                    guard !Task.isCancelled, self?.revision == token else { return }
                    self?.phase = .recognizingText
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
