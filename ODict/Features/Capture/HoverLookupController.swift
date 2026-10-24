import AppKit
import HoverLookupKit
import os

/// ODict integration only: preferences, translated messages and diagnostics.
/// Monitoring, cancellation, Accessibility and OCR live in HoverLookupKit.
@MainActor
final class HoverLookupController {
    static let preferenceKey = CaptureMethod.hover.preferenceKey
    static let preferenceChanged = Notification.Name("ODictHoverPreferenceChanged")
    private static let log = Logger(subsystem: "com.touchany.odict.mac", category: "HoverLookup")
    private let monitor = HoverLookupMonitor()

    var canBegin: () -> Bool {
        get { monitor.canBegin }
        set { monitor.canBegin = newValue }
    }
    var containsPanel: (CGPoint) -> Bool {
        get { monitor.containsPanel }
        set { monitor.containsPanel = newValue }
    }
    var onResult: ((HoverWordHit) -> Void)? {
        get { monitor.onResult }
        set { monitor.onResult = newValue }
    }
    var onFailure: ((String, CGRect) -> Void)?
    var onInteraction: (() -> Void)? {
        get { monitor.onInteraction }
        set { monitor.onInteraction = newValue }
    }
    var onDismiss: (() -> Void)? {
        get { monitor.onDismiss }
        set { monitor.onDismiss = newValue }
    }

    init() {
        monitor.onFailure = { [weak self] error, anchor in
            let message: String
            switch error {
            case .accessibilityPermission:
                message = "悬停取词需要辅助功能权限。请在设置中授权，或使用截图取词。"
            case .screenPermission:
                message = "自动识别需要屏幕录制权限。请先在设置中授权，再使用截图取词。"
            case .timedOut:
                message = "悬停取词超时，请重试，或使用截图取词框选文字。"
            case .captureFailed:
                message = "无法自动截取鼠标附近的文字，请使用截图取词框选需要查询的内容。"
            case .noText:
                message = "未识别到鼠标位置的文字，请使用截图取词框选需要查询的内容。"
            case .secureInput:
                message = "当前处于安全输入状态，已暂停自动取词。退出安全输入后，可使用截图取词。"
            case .requestBusy:
                message = "上一次取词仍在结束中，请稍后重试，或使用截图取词。"
            case .excludedTarget:
                message = "无法在当前窗口自动取词，请使用截图取词框选文字。"
            case .fallbackTargetUnavailable:
                message = "鼠标下的窗口已变化或被遮挡，请重试，或使用截图取词。"
            case .accessibilityUnavailable, .accessibilityHitTestFailed, .accessibilityCallFailed,
                 .securityInspectionFailed, .securityDepthExceeded:
                message = "无法直接读取此处文字，请使用截图取词框选需要查询的内容。"
            case .tooLong:
                message = "取词内容过长，请使用截图取词框选较小的文字区域。"
            case .recognitionFailed:
                message = "自动文字识别失败，请使用截图取词框选需要查询的内容。"
            }
            self?.onFailure?(message, anchor)
        }
        monitor.onDiagnostic = { event in
            let operation = event.accessibilityOperation?.rawValue ?? "none"
            let code = event.systemCode.map { String($0) } ?? "none"
            let targetCheck = event.targetRejection?.rawValue ?? "none"
            let foregroundPID = event.foregroundPID.map { String($0) } ?? "none"
            let windowPID = event.windowPID.map { String($0) } ?? "none"
            let windowLayer = event.windowLayer.map { String($0) } ?? "none"
            #if DEBUG
            let level: OSLogType = .default
            MemoryPhaseDiagnostics.snapshot("hover.\(event.stage.rawValue).\(event.outcome.rawValue)",
                width: event.imageWidth, height: event.imageHeight, bytesPerRow: event.imageBytesPerRow)
            #else
            let level: OSLogType = .debug
            #endif
            Self.log.log(level: level, "stage=\(event.stage.rawValue, privacy: .public) outcome=\(event.outcome.rawValue, privacy: .public) reason=\(event.reason?.rawValue ?? "none", privacy: .public) elapsedMs=\(event.milliseconds) axOperation=\(operation, privacy: .public) axCode=\(code, privacy: .public) targetCheck=\(targetCheck, privacy: .public) foregroundPID=\(foregroundPID, privacy: .public) windowPID=\(windowPID, privacy: .public) windowLayer=\(windowLayer, privacy: .public) imageWidth=\(event.imageWidth) imageHeight=\(event.imageHeight) imageBytesPerRow=\(event.imageBytesPerRow)")
        }
    }

    func updateEnabled() {
        monitor.setEnabled(UserDefaults.standard.bool(forKey: Self.preferenceKey), modifier: HoverTrigger.current.moduleModifier)
    }
    func resetInteraction() { monitor.resetInteraction() }
    func stop() { monitor.stop() }
    func cancel(dismiss: Bool = true) { monitor.cancel(dismiss: dismiss) }
}
