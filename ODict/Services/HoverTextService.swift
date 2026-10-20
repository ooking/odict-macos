import AppKit
import ApplicationServices

protocol HoverTextReading {
    func word(at point: CGPoint, primaryTop: CGFloat) async throws -> HoverWordHit?
}

/// Reads only the hit element and a bounded chain of parents, never the full AX tree.
final class HoverTextService: HoverTextReading {
    private let worker = BlockingWorkQueue(label: "com.touchany.odict.hover-text")

    func word(at point: CGPoint, primaryTop: CGFloat) async throws -> HoverWordHit? {
        let cancellation = CaptureCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await worker.perform {
                let deadline = DispatchTime.now().uptimeNanoseconds + 180_000_000
                let root = AXUIElementCreateSystemWide()
                AXUIElementSetMessagingTimeout(root, 0.08)
                var hit: AXUIElement?
                let quartzPoint = CGPoint(x: point.x, y: primaryTop - point.y)
                try cancellation.check()
                guard AXUIElementCopyElementAtPosition(root, Float(quartzPoint.x), Float(quartzPoint.y), &hit) == .success,
                      let hit else { return nil }
                var pid: pid_t = 0
                guard AXUIElementGetPid(hit, &pid) == .success,
                      pid != ProcessInfo.processInfo.processIdentifier else { return nil }
                var elements: [AXUIElement] = []
                var next: AXUIElement? = hit
                for _ in 0..<6 {
                    try cancellation.check()
                    guard DispatchTime.now().uptimeNanoseconds < deadline else { return nil }
                    guard let element = next else { break }
                    AXUIElementSetMessagingTimeout(element, 0.08)
                    if attribute(element, kAXSubroleAttribute, deadline: deadline) as? String == "AXSecureTextField" {
                        throw CaptureError.secureInput
                    }
                    elements.append(element)
                    next = attribute(element, kAXParentAttribute, deadline: deadline).flatMap { value in
                        CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
                    }
                }
                for element in elements {
                    try cancellation.check()
                    guard DispatchTime.now().uptimeNanoseconds < deadline else { return nil }
                    if let result = try readHoverWord(in: element, at: quartzPoint, primaryTop: primaryTop, cancellation: cancellation, deadline: deadline) {
                        return result
                    }
                }
                return nil
            }
        }, onCancel: { cancellation.cancel() })
    }
}

private func attribute(_ element: AXUIElement, _ name: String, deadline: UInt64) -> CFTypeRef? {
    guard DispatchTime.now().uptimeNanoseconds < deadline else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func parameter(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef, deadline: UInt64) -> CFTypeRef? {
    guard DispatchTime.now().uptimeNanoseconds < deadline else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &value) == .success else { return nil }
    return value
}

private func readHoverWord(in element: AXUIElement, at point: CGPoint, primaryTop: CGFloat,
                           cancellation: CaptureCancellation, deadline: UInt64) throws -> HoverWordHit? {
    var position = point
    guard let positionValue = AXValueCreate(.cgPoint, &position),
          let rawRange = parameter(element, kAXRangeForPositionParameterizedAttribute, positionValue, deadline: deadline),
          CFGetTypeID(rawRange) == AXValueGetTypeID() else { return nil }
    var character = CFRange()
    let rangeValue = rawRange as! AXValue
    guard AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &character),
          character.location >= 0, character.length >= 0 else { return nil }
    try cancellation.check()
    guard let count = attribute(element, kAXNumberOfCharactersAttribute, deadline: deadline) as? NSNumber,
          count.intValue > character.location else { return nil }
    // Fetch at most 512 UTF-16 units around the pointer, including full word context.
    let start = max(0, character.location - 256)
    var context = CFRange(location: start, length: min(512, count.intValue - start))
    guard let contextValue = AXValueCreate(.cfRange, &context),
          let text = parameter(element, kAXStringForRangeParameterizedAttribute, contextValue, deadline: deadline) as? String,
          text.utf16.count <= 512 else { return nil }
    try cancellation.check()
    let offset = character.location - start
    for range in HoverWords.ranges(in: text) {
        let local = NSRange(range, in: text)
        guard NSLocationInRange(offset, local), local.length <= 255,
              // A word clipped at the context boundary cannot be trusted.
              !(local.location == 0 && start > 0),
              !(NSMaxRange(local) == text.utf16.count && start + context.length < count.intValue) else { continue }
        var global = CFRange(location: start + local.location, length: local.length)
        guard let value = AXValueCreate(.cfRange, &global),
              let rawBounds = parameter(element, kAXBoundsForRangeParameterizedAttribute, value, deadline: deadline),
              CFGetTypeID(rawBounds) == AXValueGetTypeID() else { return nil }
        let boundsValue = rawBounds as! AXValue
        var bounds = CGRect.zero
        guard AXValueGetType(boundsValue) == .cgRect, AXValueGetValue(boundsValue, .cgRect, &bounds),
              HoverWords.valid(bounds), bounds.insetBy(dx: -1, dy: -1).contains(point) else { return nil }
        try cancellation.check()
        return HoverWordHit(text: String(text[range]), anchor: CaptureGeometry.quartzRect(bounds, primaryTop: primaryTop))
    }
    return nil
}
