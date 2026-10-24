import AppKit
import ApplicationServices
import HoverLookupKit

enum CaptureSource: Sendable { case selection, screenshot }

/// Capture opt-ins are independent of shortcut assignments and default to off.
enum CaptureMethod: String, CaseIterable, Identifiable {
    case selection, screenshot, hover

    var id: Self { self }
    var preferenceKey: String {
        switch self {
        case .selection: return "selectedTextLookupEnabled"
        case .screenshot: return "screenshotLookupEnabled"
        case .hover: return "hoverLookupEnabled"
        }
    }
    var title: String {
        switch self {
        case .selection: return "选中取词"
        case .screenshot: return "截图取词"
        case .hover: return "悬停取词"
        }
    }
    var usesScreenPermission: Bool { self == .screenshot }
    var permissionTitle: String { usesScreenPermission ? "屏幕录制" : "辅助功能" }
    var permissionAllowed: Bool {
        usesScreenPermission ? CapturePermissions.screenRecording : CapturePermissions.accessibility
    }
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: preferenceKey) }
}

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
        case .tooLong: return "取出的文字过长，请选择 4000 字以内的内容。"
        case .unavailable: return "无法捕获此区域，请检查屏幕权限后重新框选。"
        case .crossDisplay: return "请在同一显示器内框选，不支持跨屏截图。"
        case .recognitionFailed: return "文字识别失败，兼容重试也未成功。请稍后重试，或尝试选中取词。"
        }
    }
}

/// Keep engine faults distinct from a poor crop: both capture modes share OCR.
struct OCRFailurePresentation {
    let message: String
    let offersScreenshot: Bool

    init(_ failure: OCRFailure) {
        offersScreenshot = failure.allowsScreenshotRetry
        switch failure.kind {
        case .modelResourcesUnavailable:
            message = "文字识别引擎不可用，检测到模型缓存缺失。请重启 ODict 后重试；若仍失败，请先释放磁盘空间。可暂时使用选中取词或手动输入。"
        case .engineUnavailable:
            message = "系统文字识别引擎发生错误，兼容重试也未成功。请重启 ODict 后重试，或暂时使用选中取词、手动输入。"
        case .invalidImage:
            message = "无法处理本次图像，请使用截图取词重新框选文字。"
        case .unsupportedConfiguration:
            message = "系统不支持当前文字识别配置，请暂时使用选中取词或手动输入。"
        case .insufficientMemory:
            message = "系统文字识别引擎报告内存不足，请关闭不需要的应用后重试，或使用选中取词。"
        }
    }
}

enum CaptureText {
    static func normalize(_ raw: String, emptyError: CaptureError, maximumCount: Int = 255, preserveLines: Bool = false) throws -> String {
        guard raw.utf16.prefix(65_537).count <= 65_536 else { throw CaptureError.tooLong }
        // Stop as soon as the limit is exceeded; don't build an unbounded copy of a selection.
        var result = ""
        var pendingSpace = false
        var pendingLine = false
        var count = 0
        for character in raw {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
                if preserveLines && character.isNewline { pendingLine = !result.isEmpty }
                continue
            }
            if pendingSpace { result.append(pendingLine ? "\n" : " "); count += 1; pendingSpace = false; pendingLine = false }
            result.append(character)
            count += 1
            if count > maximumCount { throw CaptureError.tooLong }
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
    // Session-only state: a stored flag could outlive a reset of system permissions.
    private(set) static var hasRequestedScreenRecording = false

    static func requestScreenRecording() {
        guard !screenRecording else { return }
        hasRequestedScreenRecording = true
        _ = CGRequestScreenCaptureAccess()
    }

    static func authorize(screenRecording: Bool) {
        if screenRecording, !self.screenRecording, !hasRequestedScreenRecording {
            // Let the system prompt handle navigation on the first request.
            requestScreenRecording()
        } else {
            openSettings(screenRecording: screenRecording)
        }
    }

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

typealias HoverWordHit = HoverLookupKit.HoverWordHit
typealias HoverWords = HoverLookupKit.HoverWords

/// The hover gesture is independent of the shortcut that turns the feature on/off.
/// Keep the previous Control behavior when upgrading or encountering an invalid preference.
enum HoverTrigger: String, CaseIterable, Identifiable {
    case none, command, control, option, shift

    static let preferenceKey = "hoverLookupModifier"
    static var current: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .control
    }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "不使用辅助按键"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .shift: return "⇧ Shift"
        }
    }
    var instruction: String {
        switch self {
        case .none: return "鼠标停在单词上约 0.3 秒即可取词，无需按键。"
        case .command: return "按住 Command，将鼠标停在单词上约 0.3 秒即可取词。"
        case .control: return "按住 Control，将鼠标停在单词上约 0.3 秒即可取词。"
        case .option: return "按住 Option，将鼠标停在单词上约 0.3 秒即可取词。"
        case .shift: return "按住 Shift，将鼠标停在单词上约 0.3 秒即可取词。"
        }
    }
    var moduleModifier: HoverModifier { HoverModifier(rawValue: rawValue) ?? .control }
    func matches(_ flags: NSEvent.ModifierFlags) -> Bool { moduleModifier.matches(flags) }
    func isHeld(in flags: NSEvent.ModifierFlags) -> Bool { moduleModifier.isHeld(in: flags) }
}
