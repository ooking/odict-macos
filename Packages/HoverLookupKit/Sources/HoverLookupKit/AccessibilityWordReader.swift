import AppKit
import ApplicationServices

/// Bounded AX hit testing. No full-tree traversal, clipboard, simulated input,
/// AXValue document reads, or changes to another application's AX configuration.
public final class AccessibilityWordReader: HoverTextReading {
    private let worker = BlockingWorkQueue(label: "HoverLookupKit.accessibility")
    public init() {}

    public func word(at point: CGPoint, primaryTop: CGFloat) async throws -> HoverWordHit? {
        let cancellation = CaptureCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await worker.perform {
                let root = AXUIElementCreateSystemWide()
                AXUIElementSetMessagingTimeout(root, 0.08)
                let position = CGPoint(x: point.x, y: primaryTop - point.y)
                try cancellation.check()
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(root, Float(position.x), Float(position.y), &hit) == .success,
                      let hit else { throw HoverLookupError.accessibilityUnavailable }
                var pid: pid_t = 0
                guard AXUIElementGetPid(hit, &pid) == .success else { throw HoverLookupError.accessibilityUnavailable }
                guard pid != ProcessInfo.processInfo.processIdentifier else { throw HoverLookupError.excludedTarget }

                // Security inspection has its own budget. A slow parent cannot
                // spend the time reserved for reading the hit text. Unknown/slow
                // security state fails closed instead of exposing pixels to OCR.
                let security = AXReadContext(cancellation: cancellation, milliseconds: 140)
                var elements: [AXUIElement] = []
                var next: AXUIElement? = hit
                for _ in 0..<8 {
                    guard let element = next else { break }
                    let subrole = try security.attribute(element, kAXSubroleAttribute)
                    if subrole as? String == "AXSecureTextField" { throw HoverLookupError.secureInput }
                    let role = try security.attribute(element, kAXRoleAttribute) as? String
                    if role == "AXSecureTextField" { throw HoverLookupError.secureInput }
                    elements.append(element)
                    if role == kAXWindowRole || role == kAXApplicationRole || role == "AXWebArea" { next = nil; break }
                    next = try security.attribute(element, kAXParentAttribute).flatMap {
                        CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
                    }
                }
                // A deeply nested tree is not assumed safe just because its first
                // few nodes weren't password fields.
                guard next == nil else { throw HoverLookupError.accessibilityUnavailable }
                let context = AXReadContext(cancellation: cancellation, milliseconds: 240)
                // Read the hit node first; only read ancestors when it has no word.
                do {
                  for element in elements {
                    if let word = try readRangeWord(element, point: position, top: primaryTop, context: context) {
                        return word
                    }
                    if let word = try readMarkerWord(element, point: position, top: primaryTop, context: context) {
                        return word
                    }
                  }
                } catch HoverLookupError.accessibilityUnavailable {
                    // Security was checked above. An extraction timeout or failed
                    // text message may safely fall back to this region's OCR.
                    try cancellation.check()
                }
                return nil
            }
        }, onCancel: { cancellation.cancel() })
    }
}

private struct AXReadContext {
    let cancellation: CaptureCancellation
    let deadline: UInt64
    init(cancellation: CaptureCancellation, milliseconds: UInt64) {
        self.cancellation = cancellation
        deadline = DispatchTime.now().uptimeNanoseconds + milliseconds * 1_000_000
    }
    private func prepare(_ element: AXUIElement) throws {
        try cancellation.check()
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw HoverLookupError.accessibilityUnavailable }
        AXUIElementSetMessagingTimeout(element, Float(min(0.04, Double(deadline - now) / 1_000_000_000)))
    }
    func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        try prepare(element)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        try cancellation.check()
        switch error {
        case .success: return value
        case .attributeUnsupported, .noValue, .notImplemented: return nil
        default: throw HoverLookupError.accessibilityUnavailable
        }
    }
    func parameter(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws -> CFTypeRef? {
        try prepare(element)
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &value)
        try cancellation.check()
        switch error {
        case .success: return value
        case .parameterizedAttributeUnsupported, .attributeUnsupported, .noValue, .notImplemented, .illegalArgument: return nil
        default: throw HoverLookupError.accessibilityUnavailable
        }
    }
}

private func rangeValue(_ raw: CFTypeRef?) -> CFRange? {
    guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    var range = CFRange()
    guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range),
          range.location >= 0, range.length >= 0,
          range.location <= Int.max - range.length else { return nil }
    return range
}

private func boundsValue(_ raw: CFTypeRef?, at point: CGPoint) -> CGRect? {
    guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    var bounds = CGRect.zero
    guard AXValueGetType(value) == .cgRect, AXValueGetValue(value, .cgRect, &bounds),
          HoverWords.valid(bounds), bounds.insetBy(dx: -1, dy: -2).contains(point) else { return nil }
    return bounds
}

private func readRangeWord(_ element: AXUIElement, point: CGPoint, top: CGFloat,
                           context: AXReadContext) throws -> HoverWordHit? {
    var position = point
    guard let positionValue = AXValueCreate(.cgPoint, &position),
          let character = rangeValue(try context.parameter(element, kAXRangeForPositionParameterizedAttribute, positionValue)) else { return nil }
    var window: CFRange
    let count = try context.attribute(element, kAXNumberOfCharactersAttribute) as? NSNumber
    if let count, count.intValue > character.location {
        let start = max(0, character.location - 256)
        window = CFRange(location: start, length: min(512, count.intValue - start))
    } else {
        // Some text controls expose line ranges but no total character count.
        guard let line = try context.parameter(element, kAXLineForIndexParameterizedAttribute, NSNumber(value: character.location)),
              let range = rangeValue(try context.parameter(element, kAXRangeForLineParameterizedAttribute, line)),
              range.length > 0, range.length <= 512,
              character.location >= range.location, character.location < range.location + range.length else { return nil }
        window = range
    }
    guard let value = AXValueCreate(.cfRange, &window),
          let text = try context.parameter(element, kAXStringForRangeParameterizedAttribute, value) as? String,
          text.utf16.count <= 512 else { return nil }
    let offset = character.location - window.location
    for range in HoverWords.ranges(in: text) {
        let local = NSRange(range, in: text)
        guard NSLocationInRange(offset, local), local.length <= 255,
              !(local.location == 0 && window.location > 0),
              !(NSMaxRange(local) == text.utf16.count && count.map({ window.location + window.length < $0.intValue }) == true) else { continue }
        var word = CFRange(location: window.location + local.location, length: local.length)
        guard let argument = AXValueCreate(.cfRange, &word),
              let bounds = boundsValue(try context.parameter(element, kAXBoundsForRangeParameterizedAttribute, argument), at: point) else { return nil }
        return HoverWordHit(text: String(text[range]), anchor: quartzRect(bounds, primaryTop: top))
    }
    return nil
}

private func readMarkerWord(_ element: AXUIElement, point: CGPoint, top: CGFloat,
                            context: AXReadContext) throws -> HoverWordHit? {
    var position = point
    guard let value = AXValueCreate(.cgPoint, &position),
          let marker = try context.parameter(element, "AXTextMarkerForPosition", value) else { return nil }
    // WebKit/Chromium may expose Text Marker ranges instead of integer ranges.
    // Probe capabilities; never link private marker constructors or change selection.
    for name in ["AXLeftWordTextMarkerRangeForTextMarker", "AXRightWordTextMarkerRangeForTextMarker"] {
        guard let range = try context.parameter(element, name, marker),
              let length = try context.parameter(element, "AXLengthForTextMarkerRange", range) as? NSNumber,
              length.intValue > 0, length.intValue <= 255,
              let raw = try context.parameter(element, "AXStringForTextMarkerRange", range) as? String,
              raw.utf16.count <= 255 else { continue }
        let ranges = HoverWords.ranges(in: raw)
        // Multiword/dotted ranges need exact subword geometry; defer to OCR.
        guard ranges.count == 1, let word = ranges.first,
              raw[word].count == raw.trimmingCharacters(in: .whitespacesAndNewlines).count,
              let bounds = boundsValue(try context.parameter(element, "AXBoundsForTextMarkerRange", range), at: point) else { continue }
        return HoverWordHit(text: String(raw[word]), anchor: quartzRect(bounds, primaryTop: top))
    }
    return nil
}
