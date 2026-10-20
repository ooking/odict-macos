import AppKit
import ApplicationServices

enum CaptureSource: Sendable { case selection, screenshot }

struct CapturedText: Sendable {
    let text: String
    let source: CaptureSource
    let anchor: CGRect
}

enum CaptureError: LocalizedError {
    case accessibilityPermission, screenPermission, noSelection, secureInput
    case noText, tooLong, unavailable, crossDisplay, recognitionFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermission: return "选中取词需要辅助功能权限。请在设置中授权后重新取词。"
        case .screenPermission: return "截图取词需要屏幕录制权限。请在设置中授权，按系统提示重新打开应用后再取词。"
        case .noSelection: return "未读取到选中文字，请先选中单词，或使用截图取词。"
        case .secureInput: return "无法从安全输入区域取词，请在普通文本中使用。"
        case .noText: return "没有识别到文字，请重新框选清晰的单词或短语。"
        case .tooLong: return "取出的文字超过 255 字，请只选择单词或短语。"
        case .unavailable: return "无法捕获此区域，请检查屏幕权限后重新框选。"
        case .crossDisplay: return "请在同一显示器内框选，不支持跨屏截图。"
        case .recognitionFailed: return "文字识别失败，请重新框选后再试。"
        }
    }
}

enum CaptureText {
    static func normalize(_ raw: String, emptyError: CaptureError) throws -> String {
        guard raw.utf16.prefix(65_537).count <= 65_536 else { throw CaptureError.tooLong }
        // Stop as soon as the limit is exceeded; don't build an unbounded copy of a selection.
        var result = ""
        var pendingSpace = false
        for character in raw {
            if character.isWhitespace { pendingSpace = !result.isEmpty; continue }
            if pendingSpace { result.append(" "); pendingSpace = false }
            result.append(character)
            if result.count > 255 { throw CaptureError.tooLong }
        }
        guard !result.isEmpty else { throw emptyError }
        return result
    }
}

enum CaptureGeometry {
    // Quartz global coordinates originate at the main display's top left.
    static func quartzRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func hoverPanelOrigin(size: CGSize, anchor: CGRect, visible: CGRect) -> CGPoint {
        var origin = panelOrigin(size: size, anchor: anchor, visible: visible)
        guard CGRect(origin: origin, size: size).intersects(anchor.insetBy(dx: -4, dy: -4)) else { return origin }
        // Near the vertical center there may be no room above/below; prefer a side
        // placement rather than clamping the card back over the source word.
        if anchor.maxX + 8 + size.width <= visible.maxX - 8 {
            origin.x = anchor.maxX + 8
        } else if anchor.minX - 8 - size.width >= visible.minX + 8 {
            origin.x = anchor.minX - 8 - size.width
        }
        return origin
    }

    static func panelOrigin(size: CGSize, anchor: CGRect, visible: CGRect) -> CGPoint {
        let left = visible.minX + 8
        let bottom = visible.minY + 8
        let x = min(max(anchor.minX, left), max(left, visible.maxX - size.width - 8))
        let below = anchor.minY - size.height - 8
        let desiredY = below >= bottom ? below : anchor.maxY + 8
        let y = min(max(desiredY, bottom), max(bottom, visible.maxY - size.height - 8))
        return CGPoint(x: x, y: y)
    }
}

enum CapturePermissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openSettings(screenRecording: Bool) {
        let pane = screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// AX calls cannot be forcibly interrupted. A short messaging timeout and cancellation
// checks between calls keep obsolete work bounded on the one serial worker.
final class CaptureCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

struct HoverWordHit: Sendable {
    let text: String
    let anchor: CGRect
}

enum HoverWords {
    /// Keep the original String ranges: repeated words must retain separate boxes.
    static func ranges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .localized]) { _, range, _, _ in
            if let previous = ranges.last {
                let separator = text[previous.upperBound..<range.lowerBound]
                if separator == "-" || separator == "'" || separator == "’" {
                    ranges[ranges.count - 1] = previous.lowerBound..<range.upperBound
                    return
                }
            }
            ranges.append(range)
        }
        return ranges
    }

    static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
    }

    static func screenRect(_ box: CGRect, region: CGRect) -> CGRect {
        CGRect(x: region.minX + box.minX * region.width, y: region.minY + box.minY * region.height,
               width: box.width * region.width, height: box.height * region.height)
    }

    static func region(around point: CGPoint, screen: CGRect) -> CGRect {
        CGRect(x: point.x - 320, y: point.y - 80, width: 640, height: 160).intersection(screen)
    }
}
