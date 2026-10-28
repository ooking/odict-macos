import SwiftUI
import AppKit

struct LookupFooter<Trailing: View>: View {
    @ObservedObject var model: LookupModel
    let openSettings: () -> Void
    let openAISettings: () -> Void
    let captureSelection: () -> Void
    let captureScreenshot: () -> Void
    let dragWindow: (NSEvent) -> Void
    var showsCaptureTools = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.closed.fill").font(.system(size: 14)).foregroundColor(.accentColor)
                .allowsHitTesting(false)
            Text("ODict").font(.system(size: 12, weight: .semibold)).allowsHitTesting(false)
            Spacer().allowsHitTesting(false)
            PronunciationButton(text: model.query, owner: model.pronunciationOwner)
            if showsCaptureTools {
                CaptureToolTipIcon(method: .selection, icon: "text.cursor", action: captureSelection)
                CaptureToolTipIcon(method: .screenshot, icon: "viewfinder", action: captureScreenshot)
                CaptureToolTipIcon(method: .hover, icon: "cursorarrow.rays")
                Button(action: model.mode == .ai ? openAISettings : openSettings) {
                    Image(systemName: "gearshape").font(.system(size: 14))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundColor(lookupSecondaryInk)
                .help("设置（⌘,）").accessibilityLabel("设置").keyboardShortcut(",", modifiers: .command)
            }
            trailing()
        }
        .padding(.horizontal, 18).padding(.vertical, 5)
        .background { LookupDragArea(drag: dragWindow) }
    }

}

/// A passive guide for hover lookup; only explicit capture tools receive actions.
/// Pending tooltip work is bounded to one cancellable delay per visible icon.
private struct CaptureToolTipIcon: View {
    let method: CaptureMethod
    let icon: String
    let action: (() -> Void)?
    @AppStorage private var enabled: Bool
    @AppStorage(HoverTrigger.preferenceKey) private var hoverTrigger = HoverTrigger.control.rawValue
    @State private var showsGuide = false
    @State private var pendingGuide: Task<Void, Never>?

    init(method: CaptureMethod, icon: String, action: (() -> Void)? = nil) {
        self.method = method
        self.icon = icon
        self.action = action
        _enabled = AppStorage(wrappedValue: false, method.preferenceKey)
    }

    var body: some View {
        control
            .foregroundColor(enabled ? Color.accentColor : lookupSecondaryInk)
            .accessibilityLabel(method.title)
            .accessibilityValue(enabled ? "已开启" : "未开启")
            .accessibilityHint(method == .hover ? (HoverTrigger(rawValue: hoverTrigger) ?? .control).instruction : "停留鼠标查看取词示意")
            .onHover { hovering in
                dismissGuide()
                guard hovering else { return }
                pendingGuide = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 400_000_000) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    showsGuide = true
                    pendingGuide = nil
                }
            }
            .popover(isPresented: $showsGuide, arrowEdge: .top) {
                VStack(spacing: 12) {
                    HStack {
                        Text(method.title).font(AppTypography.section)
                        Spacer()
                        Text(enabled ? "已开启" : "未开启")
                            .font(AppTypography.caption).foregroundColor(.secondary)
                    }
                    CaptureMethodGuide(method: method)
                    if method == .hover {
                        Text("此图标仅展示用法，请在设置中开启或调整。")
                            .font(AppTypography.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18).frame(width: 320)
            }
            .onDisappear(perform: dismissGuide)
    }

    @ViewBuilder private var control: some View {
        if let action = action {
            Button {
                dismissGuide()
                action()
            } label: { symbol }
                .buttonStyle(.plain)
        } else {
            symbol
        }
    }

    private var symbol: some View {
        Image(systemName: icon).font(.system(size: 14))
            .frame(width: 28, height: 28).contentShape(Rectangle())
    }

    private func dismissGuide() {
        pendingGuide?.cancel()
        pendingGuide = nil
        showsGuide = false
    }
}

struct LookupIconButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    init(_ title: String, icon: String, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundColor(lookupSecondaryInk)
        .help(title).accessibilityLabel(title)
    }
}

/// Drag only the header/footer background, preserving input controls and selectable results.
struct LookupDragArea: NSViewRepresentable {
    let drag: (NSEvent) -> Void
    func makeNSView(context: Context) -> DragView { DragView(drag: drag) }
    func updateNSView(_ view: DragView, context: Context) { view.drag = drag }

    final class DragView: NSView {
        var drag: (NSEvent) -> Void
        init(drag: @escaping (NSEvent) -> Void) {
            self.drag = drag
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { drag(event) }
    }
}



/// Shared, passive presentation for lookup decisions and recoverable status messages.
/// No observers, retained services, timers or hover state are needed here.
struct LookupNotice<Actions: View>: View {
    let title: String
    let message: String
    var icon = "info.circle"
    var isBusy = false
    var source: String? = nil
    var footnote: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.09))
                    if isBusy { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: icon).font(.system(size: 17, weight: .medium))
                            .foregroundColor(.accentColor).accessibilityHidden(true)
                    }
                }.frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 17, weight: .semibold)).foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message).font(AppTypography.secondary).foregroundColor(lookupSecondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let source, !source.isEmpty { LookupSourceText(text: source) }
            actions()
            if let footnote {
                Text(footnote).font(AppTypography.caption).foregroundColor(lookupSecondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

struct LookupSourceText: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("原文").font(AppTypography.caption).foregroundColor(lookupSecondaryInk)
            ReadingText(text, fixedSize: 14).foregroundColor(.primary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// Explicit fill and contrast keep primary actions visible in light capture panels.
/// Native Button semantics, keyboard handling and focus behavior are preserved.
struct LookupActionStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .foregroundColor(prominent ? .white : .primary)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(prominent ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.09 : 0.045)))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(prominent ? Color.clear : Color.primary.opacity(0.09)))
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}
