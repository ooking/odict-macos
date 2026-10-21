import AppKit
import CoreML
import ScreenCaptureKit
import Vision

struct ScreenRegion {
    let rect: CGRect
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let scale: CGFloat
    let primaryTop: CGFloat
}

protocol ScreenImageCapturing {
    func capture(_ region: ScreenRegion) async throws -> CGImage
}

protocol ScreenTextRecognizing {
    func recognize(_ image: CGImage) async throws -> String
}

struct ScreenImageService: ScreenImageCapturing {
    func capture(_ region: ScreenRegion) async throws -> CGImage { try await Self.capture(region) }
    static func capture(_ region: ScreenRegion) async throws -> CGImage {
        try Task.checkCancellation()
        guard region.rect.width.isFinite, region.rect.height.isFinite,
              region.rect.width > 0, region.rect.height > 0,
              region.scale.isFinite, region.scale > 0,
              region.screenFrame.contains(region.rect) else { throw CaptureError.unavailable }
        if #available(macOS 14.0, *) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
                throw CaptureError.unavailable
            }
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(x: region.rect.minX - region.screenFrame.minX,
                y: region.screenFrame.maxY - region.rect.maxY, width: region.rect.width, height: region.rect.height)
            // Keep large accidental selections bounded to at most 4096 pixels on either edge.
            let scale = min(region.scale, 4096 / max(region.rect.width, region.rect.height))
            configuration.width = max(1, Int(ceil(region.rect.width * scale)))
            configuration.height = max(1, Int(ceil(region.rect.height * scale)))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()
            return image
        } else {
            // Modern capture explicitly excludes our windows. The old API needs
            // a compositor turn after the overlay is removed.
            try await Task.sleep(nanoseconds: 100_000_000)
            return try legacyCapture(region)
        }
    }

    @available(macOS, introduced: 12.0, obsoleted: 14.0)
    private static func legacyCapture(_ region: ScreenRegion) throws -> CGImage {
        let rect = CaptureGeometry.quartzRect(region.rect, primaryTop: region.primaryTop)
        let nativePixels = region.rect.width * region.rect.height * region.scale * region.scale
        let option: CGWindowImageOption = nativePixels <= 16_777_216 ? .bestResolution : .nominalResolution
        guard region.rect.width * region.rect.height <= 16_777_216,
              let image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, option) else {
            throw CaptureError.unavailable
        }
        // CoreGraphics allocates the selected region only, never a full-desktop cache.
        let longest = max(image.width, image.height)
        guard longest > 4096 else { return image }
        let scale = 4096.0 / Double(longest)
        guard let context = CGContext(data: nil, width: max(1, Int(Double(image.width) * scale)),
            height: max(1, Int(Double(image.height) * scale)), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.unavailable
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(context.width), height: CGFloat(context.height)))
        guard let resized = context.makeImage() else { throw CaptureError.unavailable }
        return resized
    }
}

// The Vision request is created, configured and read only on the serial OCR queue.
// Only cancel() may cross threads; the lock protects publication and retirement.
private final class RecognitionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRecognizeTextRequest?

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    func install(_ request: VNRecognizeTextRequest) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        self.request = request
    }

    func finish() {
        lock.lock(); request = nil; lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let activeRequest = request
        lock.unlock()
        activeRequest?.cancel()
    }
}

enum OCRComputePolicy {
    case automatic, compatibleCPU
    // Vision revision 2 supports English and Chinese on our macOS 12 baseline.
    // It is intentionally retained as a runtime-checked compatibility path.
    static let compatibilityRevision = 2

    func configure(_ request: VNRecognizeTextRequest) throws {
        request.recognitionLevel = .accurate
        if self == .compatibleCPU {
            guard VNRecognizeTextRequest.supportedRevisions.contains(Self.compatibilityRevision) else {
                throw CaptureError.recognitionFailed
            }
            request.revision = Self.compatibilityRevision
        }
        let supported = try request.supportedRecognitionLanguages()
        // A Chinese-capable model also handles Latin text; prioritizing English
        // can instead interpret Chinese glyphs as Latin punctuation or letters.
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
        request.usesLanguageCorrection = true
        guard self == .compatibleCPU else { return }
        if #available(macOS 14.0, *) {
            let stages = try request.supportedComputeStageDevices
            guard !stages.isEmpty else { throw CaptureError.recognitionFailed }
            for (stage, devices) in stages {
                guard let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) else {
                    throw CaptureError.recognitionFailed
                }
                request.setComputeDevice(cpu, for: stage)
            }
        } else { Self.configureLegacyCPU(request) }
    }

    @available(macOS, introduced: 12.0, obsoleted: 14.0)
    private static func configureLegacyCPU(_ request: VNRecognizeTextRequest) { request.usesCPUOnly = true }
}

final class ScreenTextService: ScreenTextRecognizing {
    private let queue = DispatchQueue(label: "com.touchany.odict.ocr", qos: .userInitiated)

    func recognize(_ image: CGImage) async throws -> String {
        try await recognize(image) { observations in
            let ordered = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            var rows: [[VNRecognizedTextObservation]] = []
            for observation in ordered {
                if let last = rows.last, let first = last.first,
                   abs(first.boundingBox.midY - observation.boundingBox.midY)
                    <= min(first.boundingBox.height, observation.boundingBox.height) * 0.5 {
                    rows[rows.count - 1].append(observation)
                } else { rows.append([observation]) }
            }
            var lines: [String] = []
            var length = 0
            for row in rows {
                var fragments: [String] = []
                for observation in row.sorted(by: { $0.boundingBox.minX < $1.boundingBox.minX }) {
                    guard let text = observation.topCandidates(1).first?.string else { continue }
                    length += text.count + 1
                    guard length <= AIConfiguration.maximumInput + 1 else { throw CaptureError.tooLong }
                    fragments.append(text)
                }
                if !fragments.isEmpty { lines.append(fragments.joined(separator: " ")) }
            }
            return try CaptureText.normalize(lines.joined(separator: "\n"), emptyError: .noText, maximumCount: AIConfiguration.maximumInput, preserveLines: true)
        }
    }

    func recognizeWord(_ image: CGImage, region: CGRect, point: CGPoint) async throws -> HoverWordHit? {
        try await recognize(image) { observations in
            var hits: [HoverWordHit] = []
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.35,
                      candidate.string.utf16.count <= 2048 else { continue }
                for range in HoverWords.ranges(in: candidate.string) {
                    guard let box = try? candidate.boundingBox(for: range) else { continue }
                    let bounds = HoverWords.screenRect(box.boundingBox, region: region)
                    // Do not guess the closest word when the pointer is over whitespace.
                    guard HoverWords.valid(bounds), bounds.insetBy(dx: -1, dy: -1).contains(point) else { continue }
                    // If a word touches a crop edge, retry with a manual selection rather than query a fragment.
                    guard region.insetBy(dx: 1, dy: 1).contains(bounds) else { continue }
                    let text = String(candidate.string[range])
                    guard text.count <= 255 else { continue }
                    hits.append(HoverWordHit(text: text, anchor: bounds))
                }
            }
            return hits.min { $0.anchor.width * $0.anchor.height < $1.anchor.width * $1.anchor.height }
        }
    }

    private func recognize<Value>(_ image: CGImage,
                                  consume: @escaping ([VNRecognizedTextObservation]) throws -> Value) async throws -> Value {
        let cancellation = RecognitionCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try autoreleasepool {
                            try cancellation.check()
                            let observations: [VNRecognizedTextObservation]
                            do { observations = try Self.perform(image, policy: .automatic, cancellation: cancellation) }
                            catch {
                                try cancellation.check()
                                // Retry an execution failure once with legacy Vision on CPU. Empty text or
                                // downstream word matching must never trigger another OCR.
                                do { observations = try Self.perform(image, policy: .compatibleCPU, cancellation: cancellation) }
                                catch { try cancellation.check(); throw CaptureError.recognitionFailed }
                            }
                            try cancellation.check()
                            let result = try consume(observations)
                            try cancellation.check()
                            return result
                        }
                    })
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    private static func perform(_ image: CGImage, policy: OCRComputePolicy,
                                cancellation: RecognitionCancellation) throws -> [VNRecognizedTextObservation] {
        try cancellation.check()
        let request = VNRecognizeTextRequest()
        try policy.configure(request)
        try cancellation.install(request)
        defer { cancellation.finish() }
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { try cancellation.check(); throw CaptureError.recognitionFailed }
        try cancellation.check()
        return request.results ?? []
    }
}
