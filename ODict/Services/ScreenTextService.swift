import AppKit
import HoverLookupKit

typealias ScreenRegion = HoverLookupKit.ScreenRegion
typealias OCRComputePolicy = HoverLookupKit.OCRComputePolicy

protocol ScreenImageCapturing {
    func capture(_ region: ScreenRegion) async throws -> CGImage
}

protocol ScreenTextRecognizing {
    func prepare() throws
    func recognize(_ image: CGImage) async throws -> String
}

extension ScreenTextRecognizing {
    func prepare() throws {}
}

/// Maps platform-service errors to ODict's existing capture UI.
struct ScreenImageService: ScreenImageCapturing {
    func capture(_ region: ScreenRegion) async throws -> CGImage {
        do { return try await HoverLookupKit.ScreenImageService.capture(region) }
        catch is CancellationError { throw CancellationError() }
        catch { throw CaptureError.unavailable }
    }
}

final class ScreenTextService: ScreenTextRecognizing {
    private let recognizer = HoverLookupKit.ScreenTextService()
    func prepare() throws { try recognizer.prepare() }
    func recognize(_ image: CGImage) async throws -> String {
        do {
            let result = try await recognizer.recognize(image, maximumCount: AIConfiguration.maximumInput)
            return try CaptureText.normalize(result, emptyError: .noText,
                maximumCount: AIConfiguration.maximumInput, preserveLines: true)
        } catch let error as HoverLookupError { throw captureError(error) }
    }

    func recognizeWord(_ image: CGImage, region: CGRect, point: CGPoint) async throws -> HoverWordHit? {
        do { return try await recognizer.recognizeWord(image, region: region, point: point) }
        catch let error as HoverLookupError { throw captureError(error) }
    }

    private func captureError(_ error: HoverLookupError) -> CaptureError {
        switch error {
        case .noText: return .noText
        case .tooLong: return .tooLong
        default: return .recognitionFailed
        }
    }
}
