import AppKit

private actor DeferredSelection: SelectedTextReading {
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<CapturedText, Error>] = [:]
    var count: Int { nextID }

    func read(pid: pid_t, fallbackAnchor: CGRect, primaryTop: CGFloat) async throws -> CapturedText {
        let id = nextID
        nextID += 1
        // Deliberately ignore cancellation to exercise the coordinator's stale-response guard.
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }

    func complete(_ id: Int, text: String) {
        pending.removeValue(forKey: id)?.resume(returning: CapturedText(text: text, source: .selection,
            anchor: CGRect(x: 20, y: 20, width: 40, height: 20)))
    }
}

@main
private struct ScreenCaptureChecks {
    static func rejects(_ expected: CaptureError, _ operation: () throws -> String) {
        do { _ = try operation(); preconditionFailure("expected capture error") }
        catch { precondition(error.localizedDescription == expected.localizedDescription) }
    }

    static func waitForRequests(_ count: Int, in fixture: DeferredSelection) async {
        for _ in 0..<200 {
            if await fixture.count >= count { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("selection request did not start")
    }

    @MainActor
    static func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    @MainActor
    static func main() async throws {
        let whitespace = try CaptureText.normalize(" \n hello\t world \r\n", emptyError: .noSelection)
        let chinese = try CaptureText.normalize("中文\n短语", emptyError: .noText)
        let punctuation = try CaptureText.normalize("don't re-enter", emptyError: .noText)
        let boundary = try CaptureText.normalize(String(repeating: "a", count: 255), emptyError: .noText)
        precondition(whitespace == "hello world")
        precondition(chinese == "中文 短语")
        precondition(punctuation == "don't re-enter")
        precondition(boundary.count == 255)
        rejects(.tooLong) { try CaptureText.normalize(String(repeating: "a", count: 256), emptyError: .noText) }
        rejects(.noText) { try CaptureText.normalize(" \t\n", emptyError: .noText) }
        rejects(.noSelection) { try CaptureText.normalize("", emptyError: .noSelection) }

        let rects = [CGRect(x: -1400, y: 30, width: 80, height: 30),
                     CGRect(x: 40, y: 1100, width: 80, height: 30),
                     CGRect(x: 40, y: -600, width: 80, height: 30)]
        for rect in rects {
            let quartz = CaptureGeometry.quartzRect(rect, primaryTop: 900)
            precondition(CaptureGeometry.quartzRect(quartz, primaryTop: 900) == rect)
            let visible = CGRect(x: rect.minX - 200, y: rect.minY - 100, width: 1000, height: 700)
            for size in [CGSize(width: 440, height: 440), CGSize(width: 640, height: 440)] {
                let origin = CaptureGeometry.panelOrigin(size: size, anchor: rect, visible: visible)
                precondition(visible.insetBy(dx: 8, dy: 8).contains(CGRect(origin: origin, size: size)))
            }
        }

        let suite = "com.touchany.odict.capture-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://existing.example", forKey: "apiURL")
        defaults.set(false, forKey: "KeyboardShortcuts_toggleDictionary")
        LegacyPreferencesMigration.copyMissing(from: [
            "apiURL": "https://legacy.example", "didWelcome": true,
            "recentWords": (0..<30).map { "word\($0)" },
            "KeyboardShortcuts_toggleDictionary": "legacy-shortcut", "apiKey": "dummy-must-not-copy"
        ], to: defaults)
        precondition(defaults.string(forKey: "apiURL") == "https://existing.example")
        precondition(defaults.object(forKey: "KeyboardShortcuts_toggleDictionary") as? Bool == false)
        precondition(defaults.bool(forKey: "didWelcome"))
        precondition(defaults.stringArray(forKey: "recentWords")?.count == 20)
        precondition(defaults.object(forKey: "apiKey") == nil)
        defaults.removeObject(forKey: "KeyboardShortcuts_toggleDictionary")
        LegacyPreferencesMigration.copyMissing(from: ["KeyboardShortcuts_toggleDictionary": false], to: defaults)
        precondition(defaults.object(forKey: "KeyboardShortcuts_toggleDictionary") as? Bool == false)

        let fixture = DeferredSelection()
        var prompts = 0
        var failures = 0
        let denied = CaptureCoordinator(selectedText: fixture, accessibilityAllowed: { false }, screenAllowed: { false },
            requestAccessibility: { prompts += 1 }, requestScreen: { prompts += 1 })
        denied.onFailure = { _, _ in failures += 1 }
        let anchor = CGRect(x: 50, y: 50, width: 1, height: 1)
        let pid = ProcessInfo.processInfo.processIdentifier + 1
        denied.takeSelection(pid: pid, anchor: anchor, primaryTop: 900)
        precondition(prompts == 1 && failures == 1)
        denied.takeScreenshot(anchor: anchor)
        precondition(prompts == 2 && failures == 2)
        let deniedRequests = await fixture.count
        precondition(deniedRequests == 0, "permission failures must not read content")

        var results: [String] = []
        let coordinator = CaptureCoordinator(selectedText: fixture, accessibilityAllowed: { true }, screenAllowed: { false },
            requestAccessibility: { preconditionFailure("unexpected permission request") }, requestScreen: {})
        coordinator.onResult = { results.append($0.text) }
        coordinator.takeSelection(pid: pid, anchor: anchor, primaryTop: 900)
        await waitForRequests(1, in: fixture)
        coordinator.takeSelection(pid: pid, anchor: anchor, primaryTop: 900)
        await waitForRequests(2, in: fixture)
        await fixture.complete(1, text: "new")
        await settle()
        precondition(results == ["new"])
        await fixture.complete(0, text: "old")
        await settle()
        precondition(results == ["new"], "old response must not replace the latest result")
        coordinator.takeSelection(pid: pid, anchor: anchor, primaryTop: 900)
        await waitForRequests(3, in: fixture)
        coordinator.cancel()
        await fixture.complete(2, text: "cancelled")
        await settle()
        precondition(results == ["new"], "cancelled capture must not deliver a result")
        print("Screen capture logic checks passed (no screen capture, OCR, permissions or network used).")
    }
}
