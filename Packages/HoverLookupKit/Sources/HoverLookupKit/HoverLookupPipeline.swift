import AppKit

/// Extracts one word; presentation, shortcuts, preferences and translation belong
/// to the host. Providers can be replaced without global event monitoring.
@MainActor
public final class HoverLookupPipeline {
    public var onDiagnostic: ((HoverDiagnostic) -> Void)?
    private let text: HoverTextReading
    private let image: ScreenImageCapturing
    private let makeRecognizer: () -> HoverWordRecognizing
    private var recognizer: HoverWordRecognizing?
    private let textGate = HoverRequestGate<HoverWordHit?>()
    private let imageGate = HoverRequestGate<CGImage>()
    private let recognitionGate = HoverRequestGate<HoverWordHit?>()

    public init(text: HoverTextReading = AccessibilityWordReader(),
                image: ScreenImageCapturing = ScreenImageService(),
                makeRecognizer: @escaping () -> HoverWordRecognizing = { ScreenTextService() }) {
        self.text = text; self.image = image; self.makeRecognizer = makeRecognizer
    }

    public func releaseResources() { recognizer = nil }

    public func word(in region: ScreenRegion, at point: CGPoint, allowsOCR: Bool) async throws -> HoverWordHit? {
        var stage = HoverDiagnostic.Stage.accessibility
        var started = ProcessInfo.processInfo.systemUptime
        do {
            try Task.checkCancellation()
            onDiagnostic?(HoverDiagnostic(stage, .started, since: started))
            let hit = try await textGate.run(timeout: 800_000_000) { [text] in
                try await text.word(at: point, primaryTop: region.primaryTop)
            }
            try Task.checkCancellation()
            onDiagnostic?(HoverDiagnostic(stage, hit == nil ? .miss : .hit, since: started))
            if let hit { return hit }
            guard allowsOCR else { throw HoverLookupError.screenPermission }
            stage = .capture
            started = ProcessInfo.processInfo.systemUptime
            onDiagnostic?(HoverDiagnostic(stage, .started, since: started))
            let screenshot: CGImage
            do {
                screenshot = try await imageGate.run(timeout: 2_000_000_000) { [image] in
                    try await image.capture(region)
                }
            }
            catch is CancellationError { throw CancellationError() }
            catch HoverLookupError.timedOut { throw HoverLookupError.timedOut }
            catch HoverLookupError.requestBusy { throw HoverLookupError.requestBusy }
            catch { throw HoverLookupError.captureFailed }
            try Task.checkCancellation()
            onDiagnostic?(HoverDiagnostic(stage, .hit, since: started))
            stage = .recognition
            started = ProcessInfo.processInfo.systemUptime
            onDiagnostic?(HoverDiagnostic(stage, .started, since: started))
            let reader = recognizer ?? makeRecognizer()
            recognizer = reader
            let result = try await recognitionGate.run(timeout: 3_000_000_000) {
                try await reader.recognizeWord(screenshot, region: region.rect, point: point)
            }
            try Task.checkCancellation()
            onDiagnostic?(HoverDiagnostic(stage, result == nil ? .miss : .hit, since: started))
            return result
        } catch {
            let blocked: Bool
            switch error {
            case HoverLookupError.secureInput, HoverLookupError.excludedTarget, HoverLookupError.accessibilityUnavailable, HoverLookupError.accessibilityHitTestFailed,
                 HoverLookupError.securityInspectionFailed, HoverLookupError.securityDepthExceeded, HoverLookupError.requestBusy: blocked = true
            default: blocked = false
            }
            let outcome: HoverDiagnostic.Outcome
            if error is CancellationError { outcome = .cancelled }
            else if case HoverLookupError.timedOut = error { outcome = .timedOut }
            else { outcome = blocked ? .blocked : .failed }
            let reason: HoverDiagnostic.Reason?
            switch error {
            case HoverLookupError.requestBusy: reason = .providerBusy
            case HoverLookupError.secureInput: reason = .secureInput
            case HoverLookupError.excludedTarget: reason = .ownWindow
            case HoverLookupError.accessibilityUnavailable: reason = .safetyCheck
            case HoverLookupError.accessibilityHitTestFailed: reason = .hitTestFailed
            case HoverLookupError.securityInspectionFailed: reason = .securityInspection
            case HoverLookupError.securityDepthExceeded: reason = .securityDepth
            case HoverLookupError.screenPermission: reason = .permission
            default: reason = nil
            }
            onDiagnostic?(HoverDiagnostic(stage, outcome, since: started, reason: reason))
            throw error
        }
    }
}
