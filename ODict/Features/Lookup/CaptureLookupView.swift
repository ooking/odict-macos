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

    var body: some View {
        VStack(spacing: 0) {
            LookupResultView(model: model, openSettings: openSettings,
                captureScreenshot: captureScreenshot, openAISettings: openAISettings, isCapture: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            LookupFooter(model: model, openSettings: openSettings, openAISettings: openAISettings,
                captureSelection: captureSelection, captureScreenshot: captureScreenshot, dragWindow: dragWindow) {
                LookupIconButton("关闭（Esc）", icon: "xmark", action: close)
            }
        }
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}
