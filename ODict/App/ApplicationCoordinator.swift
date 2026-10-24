import AppKit
import KeyboardShortcuts

/// Connects independent feature controllers; platform notifications are interpreted
/// here instead of being allowed to directly cancel any arbitrary in-flight task.
@MainActor
final class ApplicationCoordinator: NSObject {
    private let model: LookupModel
    private let status = MenuBarController()
    private let settings = SettingsWindowController()
    private var lastExternalPID: pid_t?
    private var captureOriginPID: pid_t?
    private var selectionReturnsToInput = false
    private var isStopping = false
    private lazy var lookup = LookupWindowController(model: model, status: status, actions: LookupWindowActions(
        openSettings: { [weak self] in self?.showSettings() },
        captureSelection: { [weak self] in self?.startSelection(inCurrentWindow: true) },
        captureScreenshot: { [weak self] in self?.startScreenshot() },
        editQuery: { [weak self] in self?.capture.cancel() },
        interacted: { [weak self] in self?.hover.cancel(dismiss: false) },
        dismissed: { [weak self] in
            self?.lookupDismissed()
        }, openAISettings: { [weak self] in self?.showSettings(ai: true) }))
    private lazy var hover: HoverLookupController = {
        let controller = HoverLookupController()
        controller.canBegin = { [weak self] in
            guard let self else { return false }
            return !self.isStopping && !self.capture.isRunning
        }
        controller.containsPanel = { point in
            NSApp.windows.contains { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(point) }
        }
        controller.onResult = { [weak self] result in
            guard let self else { return }
            self.model.lookupHovered(result.text)
            self.lookup.show(anchor: result.anchor, hover: true)
        }
        controller.onFailure = { [weak self] message, anchor in
            guard let self else { return }
            self.model.presentCaptureStatus(message, busy: false)
            self.lookup.show(anchor: anchor, hover: true)
        }
        controller.onInteraction = { [weak self] in self?.lookup.promote() }
        // Hover completion cancels recognition only; the result stays until closed.
        return controller
    }()
    private lazy var capture: CaptureCoordinator = {
        let coordinator = CaptureCoordinator()
        coordinator.onResult = { [weak self] result in
            guard let self else { return }
            if self.selectionReturnsToInput {
                self.model.lookupSelectionInInput(result.text)
                return
            }
            self.model.lookupCaptured(result.text)
            self.lookup.show(anchor: result.anchor, mode: .capture)
        }
        coordinator.onFailure = { [weak self] message, anchor in
            guard let self else { return }
            self.model.presentCaptureStatus(message, busy: false, preservingManualInput: self.selectionReturnsToInput)
            if self.selectionReturnsToInput { return }
            self.lookup.show(anchor: anchor, mode: .capture)
        }
        coordinator.onRecognizing = { [weak self] anchor in
            guard let self else { return }
            self.model.presentCaptureStatus("正在本机识别文字…", busy: true)
            self.lookup.show(anchor: anchor, mode: .capture)
        }
        coordinator.onCancelled = { [weak self] in
            guard let self else { return }
            if self.lookup.isVisible, self.model.captureIsBusy {
                self.model.presentCaptureStatus("已取消截图取词", busy: false)
            }
            if let pid = self.captureOriginPID {
                NSRunningApplication(processIdentifier: pid)?.activate(options: .activateIgnoringOtherApps)
            }
        }
        return coordinator
    }()

    override init() {
        LegacyPreferencesMigration.run()
        model = LookupModel()
        super.init()
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        rememberSource()
        status.onToggle = { [weak self] in self?.toggleLookup() }
        settings.didSave = { [weak self] in self?.dictionarySourcesChanged() }
        NotificationCenter.default.addObserver(self, selector: #selector(dictionarySourcesChanged),
            name: LocalDictionaryStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cacheSettingsChanged),
            name: LookupCacheSettings.changed, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sourceChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancelHover), name: name, object: nil)
        }
        _ = lookup
        NotificationCenter.default.addObserver(self, selector: #selector(hoverPreferenceChanged),
            name: HoverLookupController.preferenceChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(aiSettingsChanged),
            name: AISettingsStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(aiHistorySettingsChanged),
            name: AIHistorySettings.changed, object: nil)
        hover.updateEnabled()
        KeyboardShortcuts.onKeyUp(for: .toggleDictionary) { [weak self] in self?.toggleLookup() }
        KeyboardShortcuts.onKeyUp(for: .selectedTextLookup) { [weak self] in self?.startSelection() }
        KeyboardShortcuts.onKeyUp(for: .screenshotLookup) { [weak self] in self?.startScreenshot() }
        KeyboardShortcuts.onKeyUp(for: .toggleHoverLookup) { [weak self] in
            // Enabling through a shortcut must respect the same permission requirement.
            if !CaptureMethod.hover.isEnabled && !CaptureMethod.hover.permissionAllowed {
                self?.showSettings()
                return
            }
            let defaults = UserDefaults.standard
            defaults.set(!defaults.bool(forKey: HoverLookupController.preferenceKey), forKey: HoverLookupController.preferenceKey)
            NotificationCenter.default.post(name: HoverLookupController.preferenceChanged, object: nil)
        }
        if !UserDefaults.standard.bool(forKey: "didWelcome") {
            showSettings()
            UserDefaults.standard.set(true, forKey: "didWelcome")
        }
        LifecycleDiagnostics.record("launch.ready")
    }

    @objc private func aiSettingsChanged() { model.aiSettingsChanged() }
    @objc private func aiHistorySettingsChanged() { model.ai.history.settingsChanged() }

    @objc private func dictionarySourcesChanged() {
        model.sourcesChanged()
        // Settings can now remain beside lookup; refresh the visible result in place.
        if lookup.isVisible { model.resume() }
    }

    @objc private func cacheSettingsChanged() { model.cacheSettingsChanged() }

    @objc private func cancelHover() { hover.cancel() }

    @objc private func hoverPreferenceChanged() { hover.updateEnabled() }

    func toggleLookup() {
        hover.cancel()
        if lookup.isVisible && !lookup.isCapture { lookup.hide(); return }
        capture.cancel()
        rememberSource()
        lookup.show(anchor: nil)
    }

    private func lookupDismissed() {
        hover.resetInteraction()
        capture.cancel()
        model.suspend()
        // Hiding a key accessory panel does not itself reactivate the source.
        // Restore focus only when ODict still owns it and no settings are open.
        guard !isStopping, NSApp.isActive, !settings.isVisible,
              let pid = lastExternalPID,
              let source = NSRunningApplication(processIdentifier: pid), !source.isTerminated else { return }
        let restored = source.activate(options: .activateIgnoringOtherApps)
        LifecycleDiagnostics.record(restored ? "lookup.focusRestored" : "lookup.focusRestoreFailed")
    }

    private func showSettings(ai: Bool = false) {
        hover.cancel()
        settings.show(ai: ai)
    }

    private func rememberSource() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalPID = app.processIdentifier
        }
    }

    @objc private func sourceChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        lastExternalPID = app.processIdentifier
        hover.cancel()
        // Removing an OCR overlay can return focus to its original app. That is
        // an expected transition, not the user abandoning the capture operation.
        if capture.isRunning, captureOriginPID == app.processIdentifier { return }
        capture.cancel()
    }

    private func prepareCapture() -> CGRect {
        selectionReturnsToInput = false
        hover.cancel()
        rememberSource()
        captureOriginPID = lastExternalPID
        return CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 1))
    }

    private func startSelection(inCurrentWindow: Bool = false) {
        guard CaptureMethod.selection.isEnabled else { showSettings(); return }
        let anchor: CGRect
        if inCurrentWindow && lookup.isVisible && !lookup.isCapture {
            hover.cancel(dismiss: false)
            capture.cancel()
            rememberSource()
            captureOriginPID = lastExternalPID
            selectionReturnsToInput = true
            anchor = CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 1))
            model.presentCaptureStatus("正在读取选中文字…", busy: true, preservingManualInput: true)
        } else {
            anchor = prepareCapture()
        }
        capture.takeSelection(pid: captureOriginPID, anchor: anchor, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    private func startScreenshot() {
        guard CaptureMethod.screenshot.isEnabled else { showSettings(); return }
        let anchor = prepareCapture()
        // Dismiss before starting capture: dismissal also cancels active capture work.
        if lookup.isVisible { lookup.hide() }
        capture.takeScreenshot(anchor: anchor)
    }

    func becameActive() { if !isStopping { hover.updateEnabled() } }

    func resignedActive() {
        // Lookup windows stay visible when focus moves to another app.
    }

    func screenChanged() {
        hover.cancel()
        capture.cancel()
        lookup.screenChanged()
    }

    func reopen() {
        if !lookup.isVisible && !settings.isVisible { toggleLookup() }
    }

    func stop() {
        isStopping = true
        hover.stop()
        capture.cancel()
        lookup.hide()
        settings.close()
        KeyboardShortcuts.removeAllHandlers()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        status.stop()
    }

    func prepareForTermination() async -> Bool {
        isStopping = true
        hover.stop()
        capture.cancel()
        model.ai.prepareForTermination()
        return await model.ai.history.flush()
    }

    func cancelTerminationPreparation() {
        isStopping = false
        model.ai.cancelTerminationPreparation()
        hover.updateEnabled()
    }
}
