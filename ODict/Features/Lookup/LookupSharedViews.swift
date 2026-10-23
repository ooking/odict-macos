import SwiftUI
import AppKit

struct LookupFooter<Trailing: View>: View {
    @ObservedObject var model: LookupModel
    let openSettings: () -> Void
    let openAISettings: () -> Void
    let captureSelection: () -> Void
    let captureScreenshot: () -> Void
    let dragWindow: (NSEvent) -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.closed.fill").font(.system(size: 14)).foregroundColor(.accentColor)
                .allowsHitTesting(false)
            Text("ODict").font(.system(size: 12, weight: .semibold)).allowsHitTesting(false)
            Spacer().allowsHitTesting(false)
            LookupIconButton("选中取词", icon: "text.cursor", action: captureSelection)
            LookupIconButton("截图取词", icon: "viewfinder", action: captureScreenshot)
            Button(action: model.mode == .ai ? openAISettings : openSettings) {
                Image(systemName: "gearshape").font(.system(size: 14))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundColor(lookupSecondaryInk)
            .help("设置（⌘,）").accessibilityLabel("设置").keyboardShortcut(",", modifiers: .command)
            trailing()
        }
        .padding(.horizontal, 18).padding(.vertical, 5)
        .background { LookupDragArea(drag: dragWindow) }
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


