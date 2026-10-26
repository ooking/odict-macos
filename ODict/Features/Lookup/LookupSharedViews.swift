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


