import SwiftUI
import AppKit

/// Capture results have their own layout, without the manual lookup composer.
struct CaptureLookupView: View {
    @ObservedObject var model: LookupModel
    let openSettings: () -> Void
    let close: () -> Void
    let captureSelection: () -> Void
    let captureScreenshot: () -> Void
    let openAISettings: () -> Void
    let dragWindow: (NSEvent) -> Void
    @ObservedObject var presentation: LookupPresentation
    let togglePin: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            LookupResultView(model: model, openSettings: openSettings,
                openAISettings: openAISettings, isCapture: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            LookupFooter(model: model, openSettings: openSettings, openAISettings: openAISettings,
                captureSelection: captureSelection, captureScreenshot: captureScreenshot, dragWindow: dragWindow,
                showsCaptureTools: false) {
                Button(action: togglePin) {
                    Image(systemName: presentation.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(presentation.isPinned ? Color.accentColor : lookupSecondaryInk)
                .help(presentation.isPinned ? "取消固定位置" : "固定窗口位置")
                .accessibilityLabel(presentation.isPinned ? "取消固定位置" : "固定窗口位置")
                .accessibilityValue(presentation.isPinned ? "已固定" : "未固定")
                LookupIconButton("关闭", icon: "xmark", action: close)
            }
        }
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}
