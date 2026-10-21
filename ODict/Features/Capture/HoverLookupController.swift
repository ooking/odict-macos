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
            case .screenPermission:
                message = "此处无法直接读取文字，需要屏幕录制权限进行识别。请在设置中授权，或尝试选中取词。"
            case .captureFailed:
                message = "无法截取鼠标附近的文字，请检查屏幕录制权限，或尝试选中取词。"
            default:
                message = CaptureError.recognitionFailed.localizedDescription
            }
            self?.onFailure?(message, anchor)
        }
        monitor.onDiagnostic = { event in
            Self.log.debug("stage=\(event.stage.rawValue, privacy: .public) outcome=\(event.outcome.rawValue, privacy: .public) elapsedMs=\(event.milliseconds)")
        }
    }

    func updateEnabled() {
        monitor.setEnabled(UserDefaults.standard.bool(forKey: Self.preferenceKey), modifier: HoverTrigger.current.moduleModifier)
    }
    func stop() { monitor.stop() }
    func cancel(dismiss: Bool = true) { monitor.cancel(dismiss: dismiss) }
}
