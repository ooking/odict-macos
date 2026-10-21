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
            try await worker.perform {
                try cancellation.check()
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.35)
                var focused: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                      let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
                    throw CaptureError.noSelection
                }
                let element = focused as! AXUIElement
                AXUIElementSetMessagingTimeout(element, 0.35)
                try cancellation.check()
                var subrole: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
                guard (subrole as? String) != "AXSecureTextField" else { throw CaptureError.secureInput }
                try cancellation.check()
                var raw: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &raw) == .success,
                      let value = raw as? String else { throw CaptureError.noSelection }
                let text = try CaptureText.normalize(value, emptyError: .noSelection, maximumCount: AIConfiguration.maximumInput, preserveLines: true)
                try cancellation.check()
                var anchor = fallbackAnchor
                var range: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
                   let range {
                    try cancellation.check()
                    var bounds: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                                  range, &bounds) == .success,
                       let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() {
                        let axValue = bounds as! AXValue
                        var rect = CGRect.zero
                        if AXValueGetType(axValue) == .cgRect, AXValueGetValue(axValue, .cgRect, &rect),
                           !rect.isEmpty, !rect.isInfinite, !rect.isNull,
                           rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite {
                            anchor = CaptureGeometry.quartzRect(rect, primaryTop: primaryTop)
                        }
                    }
                }
                try cancellation.check()
                return CapturedText(text: text, source: .selection, anchor: anchor)
            }
        }, onCancel: { cancellation.cancel() })
    }
}
