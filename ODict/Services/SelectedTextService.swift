import AppKit
import ApplicationServices

protocol SelectedTextReading {
    func read(pid: pid_t, fallbackAnchor: CGRect, primaryTop: CGFloat) async throws -> CapturedText
}

final class SelectedTextService: SelectedTextReading {
    private let worker = BlockingWorkQueue(label: "com.touchany.odict.selected-text")

    func read(pid: pid_t, fallbackAnchor: CGRect, primaryTop: CGFloat) async throws -> CapturedText {
        let cancellation = CaptureCancellation()
        return try await withTaskCancellationHandler(operation: {
            // Electron may expose text only after an assistive client enables
            // accessibility. Retry once after allowing its tree to update.
            for attempt in 0..<2 {
                let result: CapturedText? = try await worker.perform {
                    let reader = SelectionReader(pid: pid, cancellation: cancellation)
                    do {
                        if let result = try reader.read(fallbackAnchor: fallbackAnchor, primaryTop: primaryTop) {
                            return result
                        }
                    } catch CaptureError.noSelection {
                        // An uninitialized accessibility tree may time out too.
                    }
                    if attempt == 0 { try reader.enableAccessibility() }
                    return nil
                }
                if let result { return result }
                if attempt == 0 { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            throw CaptureError.noSelection
        }, onCancel: { cancellation.cancel() })
    }
}

/// Inspect only the focused element and up to three parents in the source app.
/// No full-tree traversal, clipboard access, or retained external AX objects.
private struct SelectionReader {
    let pid: pid_t
    let cancellation: CaptureCancellation
    private let deadline = DispatchTime.now().uptimeNanoseconds + 800_000_000

    func enableAccessibility() throws {
        try cancellation.check()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        // Chromium enables native accessibility when an assistive client reads
        // the application's role. Electron also supports an explicit opt-in.
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &role)
        try cancellation.check()
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    func read(fallbackAnchor: CGRect, primaryTop: CGFloat) throws -> CapturedText? {
        let app = AXUIElementCreateApplication(pid)
        var focused = try elementAttribute(app, kAXFocusedUIElementAttribute)
        if focused == nil {
            let system = AXUIElementCreateSystemWide()
            focused = try elementAttribute(system, kAXFocusedUIElementAttribute)
            if let candidate = focused, !belongsToSource(candidate) { focused = nil }
        }
        if focused == nil, let window = try elementAttribute(app, kAXFocusedWindowAttribute) {
            focused = try elementAttribute(window, kAXFocusedUIElementAttribute) ?? window
        }
        var elements: [AXUIElement] = []
        for _ in 0..<4 {
            guard let element = focused, belongsToSource(element),
                  !elements.contains(where: { CFEqual($0, element) }) else { break }
            if try attribute(element, kAXSubroleAttribute) as? String == "AXSecureTextField" {
                throw CaptureError.secureInput
            }
            elements.append(element)
            focused = try elementAttribute(element, kAXParentAttribute)
        }
        for element in elements {
            let selectedRange = try attribute(element, kAXSelectedTextRangeAttribute)
            var selected = try attribute(element, kAXSelectedTextAttribute) as? String
            if selected?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               let selectedRange, CFGetTypeID(selectedRange) == AXValueGetTypeID() {
                let value = selectedRange as! AXValue
                var range = CFRange()
                if AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range),
                   range.location >= 0, range.length > 0 {
                    // Bound the request itself; never fetch the entire document.
                    guard range.length <= 65_536 else { throw CaptureError.tooLong }
                    selected = try parameter(element, kAXStringForRangeParameterizedAttribute, selectedRange) as? String
                }
            }
            // Web selections may span multiple text nodes and use text markers
            // instead of a numeric range on a single control.
            if selected?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               let markers = try attribute(element, "AXSelectedTextMarkerRange") {
                selected = try parameter(element, "AXStringForTextMarkerRange", markers) as? String
            }
            guard let selected, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let text = try CaptureText.normalize(selected, emptyError: .noSelection,
                maximumCount: AIConfiguration.maximumInput, preserveLines: true)
            var anchor = fallbackAnchor
            if let selectedRange,
               let bounds = try parameter(element, kAXBoundsForRangeParameterizedAttribute, selectedRange),
               CFGetTypeID(bounds) == AXValueGetTypeID() {
                let value = bounds as! AXValue
                var rect = CGRect.zero
                if AXValueGetType(value) == .cgRect, AXValueGetValue(value, .cgRect, &rect), HoverWords.valid(rect) {
                    anchor = CaptureGeometry.quartzRect(rect, primaryTop: primaryTop)
                }
            }
            try check()
            return CapturedText(text: text, source: .selection, anchor: anchor)
        }
        return nil
    }

    private func check() throws {
        try cancellation.check()
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw CaptureError.noSelection }
    }

    private func belongsToSource(_ element: AXUIElement) -> Bool {
        var owner: pid_t = 0
        return AXUIElementGetPid(element, &owner) == .success && owner == pid
    }

    private func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        try check()
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) throws -> AXUIElement? {
        guard let value = try attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func parameter(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws -> CFTypeRef? {
        try check()
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &value) == .success else { return nil }
        return value
    }
}
