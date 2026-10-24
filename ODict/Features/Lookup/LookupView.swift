import SwiftUI
import AppKit

enum LookupWindowLayout {
    static let defaultSize = NSSize(width: 480, height: 440)
    static let minimumSize = NSSize(width: 440, height: 360)
}

enum LookupPresentationMode {
    case manual
    case capture
}

/// Shared presentation state; the window controller owns behavior and lifetime.
@MainActor
final class LookupPresentation: ObservableObject {
    @Published var mode: LookupPresentationMode = .manual
    @Published var isPinned = false
}

struct LookupView: View {
    @ObservedObject var model: LookupModel
    let openSettings: () -> Void
    let close: () -> Void
    let captureSelection: () -> Void
    let captureScreenshot: () -> Void
    let editQuery: () -> Void
    let openAISettings: () -> Void
    @ObservedObject var presentation: LookupPresentation
    let dragWindow: (NSEvent) -> Void
    var togglePin: () -> Void = {}

    var body: some View {
        Group {
            switch presentation.mode {
            case .manual:
                MainLookupView(model: model, openSettings: openSettings, close: close,
                    captureSelection: captureSelection, captureScreenshot: captureScreenshot,
                    editQuery: editQuery, openAISettings: openAISettings, dragWindow: dragWindow)
            case .capture:
                CaptureLookupView(model: model, openSettings: openSettings, close: close,
                    captureSelection: captureSelection, captureScreenshot: captureScreenshot,
                    openAISettings: openAISettings, dragWindow: dragWindow,
                    presentation: presentation, togglePin: togglePin)
            }
        }
        .font(AppTypography.body)
        .frame(minWidth: LookupWindowLayout.minimumSize.width, maxWidth: .infinity,
               minHeight: LookupWindowLayout.minimumSize.height, maxHeight: .infinity)
        .onExitCommand { if presentation.mode == .manual { close() } }
    }
}
