import AppKit
import Carbon

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
            let hit: HoverWordHit?
            var fallback: AccessibilityOCRFallback?
            do {
                hit = try await textGate.run(timeout: 800_000_000) { [text] in
                    try await text.word(at: point, primaryTop: region.primaryTop)
                }
            } catch let approval as AccessibilityOCRFallback {
                fallback = approval
                hit = nil
            }
            try Task.checkCancellation()
            if let fallback {
                onDiagnostic?(HoverDiagnostic(stage, .fallback, since: started, reason: .unsupportedInterface,
                    accessibilityOperation: fallback.operation, systemCode: fallback.code, windowPID: fallback.targetPID))
            } else {
                onDiagnostic?(HoverDiagnostic(stage, hit == nil ? .miss : .hit, since: started))
            }
            if let hit { return hit }
            guard allowsOCR else { throw HoverLookupError.screenPermission }
            let reader = recognizer ?? makeRecognizer()
            recognizer = reader
            stage = .recognition
            started = ProcessInfo.processInfo.systemUptime
            try reader.prepare()
            stage = .capture
            started = ProcessInfo.processInfo.systemUptime
            onDiagnostic?(HoverDiagnostic(stage, .started, since: started))
            let screenshot: CGImage
            let fallbackTarget = fallback
            do {
                screenshot = try await imageGate.run(timeout: 2_000_000_000) { [image] in
                    guard !IsSecureEventInputEnabled() else { throw HoverLookupError.secureInput }
                    if let fallbackTarget {
                        try await UnsupportedAccessibilityTarget.revalidate(fallbackTarget)
                    }
                    try Task.checkCancellation()
                    guard !IsSecureEventInputEnabled() else { throw HoverLookupError.secureInput }
                    return try await image.capture(region)
                }
            }
            catch is CancellationError { throw CancellationError() }
            catch HoverLookupError.secureInput { throw HoverLookupError.secureInput }
            catch let rejection as FallbackTargetRejection { throw rejection }
            catch HoverLookupError.fallbackTargetUnavailable { throw HoverLookupError.fallbackTargetUnavailable }
            catch HoverLookupError.timedOut { throw HoverLookupError.timedOut }
            catch HoverLookupError.requestBusy { throw HoverLookupError.requestBusy }
            catch { throw HoverLookupError.captureFailed }
            try Task.checkCancellation()
            onDiagnostic?(HoverDiagnostic(stage, .hit, since: started,
                imageWidth: screenshot.width, imageHeight: screenshot.height, imageBytesPerRow: screenshot.bytesPerRow))
            stage = .recognition
            started = ProcessInfo.processInfo.systemUptime
            onDiagnostic?(HoverDiagnostic(stage, .started, since: started))
            let result = try await recognitionGate.run(timeout: 3_000_000_000) {
                try await reader.recognizeWord(screenshot, region: region.rect, point: point)
            }
            try Task.checkCancellation()
            onDiagnostic?(HoverDiagnostic(stage, result == nil ? .miss : .hit, since: started))
            return result
        } catch {
            let blocked: Bool
            switch error {
            case is FallbackTargetRejection: blocked = true
            case HoverLookupError.secureInput, HoverLookupError.excludedTarget, HoverLookupError.accessibilityUnavailable, HoverLookupError.accessibilityHitTestFailed,
                 HoverLookupError.securityInspectionFailed, HoverLookupError.securityDepthExceeded,
                 HoverLookupError.accessibilityCallFailed, HoverLookupError.fallbackTargetUnavailable, HoverLookupError.requestBusy: blocked = true
            default: blocked = false
            }
            let outcome: HoverDiagnostic.Outcome
            if error is CancellationError { outcome = .cancelled }
            else if case HoverLookupError.timedOut = error { outcome = .timedOut }
            else { outcome = blocked ? .blocked : .failed }
            let reason: HoverDiagnostic.Reason?
            switch error {
            case let failure as OCRFailure:
                reason = failure.kind == .modelResourcesUnavailable ? .ocrModelResources : .ocrEngine
            case HoverLookupError.requestBusy: reason = .providerBusy
            case HoverLookupError.fallbackTargetUnavailable, is FallbackTargetRejection: reason = .fallbackTarget
            case HoverLookupError.secureInput: reason = .secureInput
            case HoverLookupError.excludedTarget: reason = .ownWindow
            case HoverLookupError.accessibilityUnavailable: reason = .safetyCheck
            case HoverLookupError.accessibilityHitTestFailed, HoverLookupError.accessibilityCallFailed: reason = .hitTestFailed
            case HoverLookupError.securityInspectionFailed: reason = .securityInspection
            case HoverLookupError.securityDepthExceeded: reason = .securityDepth
            case HoverLookupError.screenPermission: reason = .permission
            default: reason = nil
            }
            let operation: HoverDiagnostic.AccessibilityOperation?
            let systemCode: Int32?
            if case let HoverLookupError.accessibilityCallFailed(call, code) = error {
                operation = call
                systemCode = code
            } else {
                operation = nil
                systemCode = nil
            }
            let rejection = error as? FallbackTargetRejection
            onDiagnostic?(HoverDiagnostic(stage, outcome, since: started, reason: reason,
                accessibilityOperation: operation, systemCode: systemCode,
                targetRejection: rejection?.reason, foregroundPID: rejection?.foregroundPID,
                windowPID: rejection?.windowPID, windowLayer: rejection?.windowLayer))
            throw error
        }
    }
}
