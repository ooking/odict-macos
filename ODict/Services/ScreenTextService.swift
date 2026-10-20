import AppKit
import ScreenCaptureKit
import Vision

struct ScreenRegion {
    let rect: CGRect
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let scale: CGFloat
    let primaryTop: CGFloat
}

enum ScreenImageService {
    static func capture(_ region: ScreenRegion) async throws -> CGImage {
        try Task.checkCancellation()
        // Allow the compositor to remove the selection windows before taking a single image.
        try await Task.sleep(nanoseconds: 100_000_000)
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
            return try legacyCapture(region)
        }
    }

    @available(macOS, introduced: 12.0, obsoleted: 14.0)
    private static func legacyCapture(_ region: ScreenRegion) throws -> CGImage {
        let rect = CaptureGeometry.quartzRect(region.rect, primaryTop: region.primaryTop)
        guard let image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
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

final class ScreenTextService {
    private let queue = DispatchQueue(label: "com.touchany.odict.ocr", qos: .userInitiated)

    func recognize(_ image: CGImage) async throws -> String {
        let cancellation = RecognitionCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try autoreleasepool {
                            try cancellation.check()
                            let request = VNRecognizeTextRequest()
                            request.recognitionLevel = .accurate
                            let supported = try request.supportedRecognitionLanguages()
                            request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"].filter { supported.contains($0) }
                            request.usesLanguageCorrection = true
                            try cancellation.install(request)
                            defer { cancellation.finish() }
                            do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
                            catch { try cancellation.check(); throw CaptureError.recognitionFailed }
                            try cancellation.check()
                            let observations = request.results ?? []
                            // Group rows by vertical overlap, then read each row left to right.
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
                                for observation in row.sorted(by: { $0.boundingBox.minX < $1.boundingBox.minX }) {
                                    guard let text = observation.topCandidates(1).first?.string else { continue }
                                    length += text.count + (lines.isEmpty ? 0 : 1)
                                    guard length <= 1024 else { throw CaptureError.tooLong }
                                    lines.append(text)
                                }
                            }
                            return try CaptureText.normalize(lines.joined(separator: " "), emptyError: .noText)
                        }
                    })
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}
