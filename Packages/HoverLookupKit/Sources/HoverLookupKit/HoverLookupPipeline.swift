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
            let hit = try await text.word(at: point, primaryTop: region.primaryTop)
            try Task.checkCancellation()
            onDiagnostic?(HoverDiagnostic(stage, hit == nil ? .miss : .hit, since: started))
            if let hit { return hit }
            guard allowsOCR else { throw HoverLookupError.screenPermission }
            stage = .capture
            started = ProcessInfo.processInfo.systemUptime
            onDiagnostic?(HoverDiagnostic(stage, .started, since: started))
            let screenshot: CGImage
            do { screenshot = try await image.capture(region) }
            catch is CancellationError { throw CancellationError() }
            catch { throw HoverLookupError.captureFailed }
            try Task.checkCancellation()
            onDiagnostic?(HoverDiagnostic(stage, .hit, since: started))
            stage = .recognition
            started = ProcessInfo.processInfo.systemUptime
            onDiagnostic?(HoverDiagnostic(stage, .started, since: started))
            let reader = recognizer ?? makeRecognizer()
            recognizer = reader
            let result = try await reader.recognizeWord(screenshot, region: region.rect, point: point)
            try Task.checkCancellation()
            onDiagnostic?(HoverDiagnostic(stage, result == nil ? .miss : .hit, since: started))
            return result
        } catch {
            let blocked: Bool
            switch error {
            case HoverLookupError.secureInput, HoverLookupError.excludedTarget, HoverLookupError.accessibilityUnavailable: blocked = true
            default: blocked = false
            }
            onDiagnostic?(HoverDiagnostic(stage, error is CancellationError ? .cancelled : blocked ? .blocked : .failed, since: started))
            throw error
        }
    }
}
