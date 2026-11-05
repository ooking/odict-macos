import SwiftUI
import AppKit

enum LookupWindowLayout {
    static let defaultSize = NSSize(width: 480, height: 600)
    static let minimumCaptureHeight: CGFloat = 160
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
    @Published var fitsContentHeight = false
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
    var openSetup: (SettingsCategory) -> Void = { _ in }
    var contentHeightChanged: (CGFloat) -> Void = { _ in }

    var body: some View {
        Group {
            switch presentation.mode {
            case .manual:
                MainLookupView(model: model, openSettings: openSettings, close: close,
                    captureSelection: captureSelection, captureScreenshot: captureScreenshot,
                    editQuery: editQuery, openAISettings: openAISettings, dragWindow: dragWindow, openSetup: openSetup)
            case .capture:
                CaptureLookupView(model: model, openSettings: openSettings, close: close,
                    captureSelection: captureSelection, captureScreenshot: captureScreenshot,
                    openAISettings: openAISettings, dragWindow: dragWindow,
                    presentation: presentation, togglePin: togglePin, contentHeightChanged: contentHeightChanged)
            }
        }
        .font(AppTypography.body)
        .frame(minWidth: LookupWindowLayout.minimumSize.width, maxWidth: .infinity,
               minHeight: presentation.mode == .capture && presentation.fitsContentHeight
                    ? LookupWindowLayout.minimumCaptureHeight : LookupWindowLayout.minimumSize.height, maxHeight: .infinity)
        .onExitCommand { if presentation.mode == .manual { close() } }
    }
}

/// Window preferences are separate from query data and contain no sensitive values.
enum CaptureWindowSettings {
    static let closesOnOutsideClickKey = "lookup.capture.closesOnOutsideClick"
    static let fitsContentHeightKey = "lookup.capture.fitsContentHeight"
    static let defaultWidthKey = "lookup.capture.defaultWidth"
    static let defaultWidth = 480
    static let widthRange = 440...1200
    static let transparencyKey = "lookup.capture.transparency"
    static let defaultTransparency = 0.0
    static let transparencyRange = 0.0...50.0
    static let widthChanged = Notification.Name("CaptureWindowSettings.widthChanged")
    static let appearanceChanged = Notification.Name("CaptureWindowSettings.appearanceChanged")
    static let maximumHeightKey = "lookup.capture.maximumHeight"
    static let defaultMaximumHeight = 720
    static let maximumHeightRange = 240...1200
    static let changed = Notification.Name("CaptureWindowSettings.changed")

    static func boundedWidth(_ width: Int) -> Int {
        min(max(width, widthRange.lowerBound), widthRange.upperBound)
    }

    static func width(in preferences: UserDefaults) -> CGFloat {
        let saved = preferences.object(forKey: defaultWidthKey) as? Int ?? defaultWidth
        return CGFloat(boundedWidth(saved))
    }

    static func boundedTransparency(_ transparency: Double) -> Double {
        guard transparency.isFinite else { return defaultTransparency }
        return min(max(transparency, transparencyRange.lowerBound), transparencyRange.upperBound)
    }

    static func alpha(in preferences: UserDefaults) -> CGFloat {
        let saved = preferences.object(forKey: transparencyKey) as? Double ?? defaultTransparency
        return CGFloat(1 - boundedTransparency(saved) / 100)
    }

    static func boundedMaximumHeight(_ height: Int) -> Int {
        min(max(height, maximumHeightRange.lowerBound), maximumHeightRange.upperBound)
    }

    static func maximumHeight(in preferences: UserDefaults) -> CGFloat {
        let saved = preferences.object(forKey: maximumHeightKey) as? Int ?? defaultMaximumHeight
        return CGFloat(boundedMaximumHeight(saved))
    }
}

private struct MeasuresLookupContent: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var measuresLookupContent: Bool {
        get { self[MeasuresLookupContent.self] }
        set { self[MeasuresLookupContent.self] = newValue }
    }
}

enum CaptureHeightPart: Hashable { case result, footer, notice }

struct CaptureContentHeights: PreferenceKey {
    static let defaultValue: [CaptureHeightPart: CGFloat] = [:]
    static func reduce(value: inout [CaptureHeightPart: CGFloat], nextValue: () -> [CaptureHeightPart: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

extension View {
    /// Read the natural content inside a scroll view, never the scroll viewport.
    func reportCaptureHeight(_ enabled: Bool, part: CaptureHeightPart = .result) -> some View {
        background {
            if enabled {
                GeometryReader { geometry in
                    Color.clear.preference(key: CaptureContentHeights.self, value: [part: geometry.size.height])
                }
            }
        }
    }
}
