import SwiftUI
import KeyboardShortcuts

/// Static, resolution-independent guides. Only the selected guide is mounted;
/// no image decoding, animation, event monitoring or capture service is needed.
struct CaptureMethodGuide: View {
    let method: CaptureMethod
    @AppStorage(HoverTrigger.preferenceKey) private var hoverTrigger = HoverTrigger.control.rawValue
    @State private var shortcutDescription: String?

    private var instruction: String {
        method.guideInstruction(
            hoverTrigger: HoverTrigger(rawValue: hoverTrigger) ?? .control,
            shortcutDescription: shortcutDescription
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            illustration
                .frame(maxWidth: .infinity)
                .frame(height: 132)
                .accessibilityHidden(true)
            Text(instruction)
                .font(AppTypography.secondary)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .onAppear(perform: refreshShortcut)
        .onChange(of: method) { _ in refreshShortcut() }
        .onReceive(NotificationCenter.default.publisher(for: CaptureMethod.guideShortcutChanged)) { notification in
            guard notification.object as? String == method.guideShortcutName.rawValue else { return }
            refreshShortcut()
        }
    }

    private func refreshShortcut() {
        shortcutDescription = KeyboardShortcuts.getShortcut(for: method.guideShortcutName)?.description
    }

    private var illustration: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: method == .screenshot ? "photo" : "doc.text")
                Text(method == .screenshot ? "图片或视频中的文字" : "其他应用中的文字")
            }
            .font(AppTypography.caption)
            .foregroundColor(.secondary)

            HStack(spacing: 6) {
                Text("Say")
                Text("hello")
                    .foregroundColor(method == .selection ? Color.accentColor : .primary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(method == .selection ? Color.accentColor.opacity(0.18) : Color.clear)
                    .cornerRadius(3)
                    .overlay(alignment: .bottomTrailing) {
                        if method == .hover {
                            Image(systemName: "cursorarrow")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundColor(.accentColor)
                                .offset(x: 10, y: 13)
                        }
                    }
                Text("to the world.")
            }
            .font(.system(size: 19, weight: .medium, design: .serif))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay {
                if method == .screenshot {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "plus").font(.system(size: 16, weight: .medium))
                                .foregroundColor(.accentColor).offset(x: 8, y: 8)
                        }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "arrow.down").foregroundColor(.secondary)
                Text("hello").fontWeight(.medium)
                Text("你好；打招呼").foregroundColor(.secondary)
            }
            .font(AppTypography.secondary)
        }
        .padding(12)
    }
}

/// Shared wording keeps settings and footer guides aligned with the configured trigger.
extension CaptureMethod {
    // Recorder callbacks publish only configuration changes. Visible guides subscribe
    // locally; no global event monitor, polling, or retained observer is needed.
    static let guideShortcutChanged = Notification.Name("ODict.captureGuideShortcutChanged")

    var guideShortcutName: KeyboardShortcuts.Name {
        switch self {
        case .selection: return .selectedTextLookup
        case .screenshot: return .screenshotLookup
        case .hover: return .toggleHoverLookup
        }
    }

    func guideInstruction(hoverTrigger: HoverTrigger, shortcutDescription: String?) -> String {
        switch self {
        case .selection:
            guard let shortcutDescription else {
                return "未设置快捷键，请先在设置中录入。选中文字后，按快捷键查看释义。"
            }
            return "选中文字 → 按 \(shortcutDescription) → 查看释义"
        case .screenshot:
            guard let shortcutDescription else {
                return "未设置快捷键，请先在设置中录入。按快捷键后框选文字区域，在本机识别并查询。"
            }
            return "按 \(shortcutDescription) → 框选文字区域 → 本机识别并查询"
        case .hover:
            let toggle = shortcutDescription.map { "开启 / 关闭悬停取词：\($0)" }
                ?? "开启 / 关闭悬停取词：未设置快捷键，可在设置中调整。"
            return hoverTrigger.instruction + "\n" + toggle
        }
    }
}
