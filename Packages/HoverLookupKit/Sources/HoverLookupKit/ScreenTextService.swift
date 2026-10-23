import AppKit
import CoreML
import Vision

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

public enum OCRComputePolicy {
    case automatic, compatibleCPU
    // Vision revision 2 supports English and Chinese on our macOS 12 baseline.
    // It is intentionally retained as a runtime-checked compatibility path.
    public static let compatibilityRevision = 2

    public func configure(_ request: VNRecognizeTextRequest) throws {
        request.recognitionLevel = .accurate
        if self == .compatibleCPU {
            guard VNRecognizeTextRequest.supportedRevisions.contains(Self.compatibilityRevision) else {
                throw HoverLookupError.recognitionFailed
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
            guard !stages.isEmpty else { throw HoverLookupError.recognitionFailed }
            for (stage, devices) in stages {
                guard let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) else {
                    throw HoverLookupError.recognitionFailed
                }
                request.setComputeDevice(cpu, for: stage)
            }
        } else { Self.configureLegacyCPU(request) }
    }

    @available(macOS, introduced: 12.0, obsoleted: 14.0)
    private static func configureLegacyCPU(_ request: VNRecognizeTextRequest) { request.usesCPUOnly = true }
}

public final class ScreenTextService: HoverWordRecognizing {
    public init() {}
    // A cancelled caller can return before Vision exits. Share one serial worker
    // so releasing/recreating recognizers cannot overlap abandoned OCR calls.
    private static let worker = BlockingWorkQueue(label: "HoverLookupKit.ocr")

    public func recognize(_ image: CGImage, maximumCount: Int = 4000) async throws -> String {
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
                    guard length <= min(max(1, maximumCount), 65_536) + 1 else { throw HoverLookupError.tooLong }
                    fragments.append(text)
                }
                if !fragments.isEmpty { lines.append(fragments.joined(separator: " ")) }
            }
            let result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else { throw HoverLookupError.noText }
            guard result.count <= min(max(1, maximumCount), 65_536) else { throw HoverLookupError.tooLong }
            return result
        }
    }

    public func recognizeWord(_ image: CGImage, region: CGRect, point: CGPoint) async throws -> HoverWordHit? {
        try await recognize(image) { observations in
            var best: HoverWordHit?
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.35,
                      candidate.string.utf16.count <= 2048 else { continue }
                for range in HoverWords.ranges(in: candidate.string) {
                    guard let box = try? candidate.boundingBox(for: range) else { continue }
                    let bounds = HoverWords.screenRect(box.boundingBox, region: region)
                    // Do not guess the closest word when the pointer is over whitespace.
                    guard HoverWords.valid(bounds), bounds.insetBy(dx: -1, dy: -2).contains(point) else { continue }
                    // If a word touches a crop edge, retry with a manual selection rather than query a fragment.
                    guard region.insetBy(dx: 1, dy: 1).contains(bounds) else { continue }
                    let text = String(candidate.string[range])
                    guard text.count <= 255 else { continue }
                    let hit = HoverWordHit(text: text, anchor: bounds)
                    if best == nil || bounds.width * bounds.height < best!.anchor.width * best!.anchor.height { best = hit }
                }
            }
            return best
        }
    }

    private func recognize<Value: Sendable>(_ image: CGImage,
                                  consume: @escaping @Sendable ([VNRecognizedTextObservation]) throws -> Value) async throws -> Value {
        let cancellation = RecognitionCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await Self.worker.perform {
                try cancellation.check()
                let observations: [VNRecognizedTextObservation]
                do { observations = try Self.perform(image, policy: .automatic, cancellation: cancellation) }
                catch {
                    try cancellation.check()
                    // Retry execution failures once, never empty recognition or word misses.
                    do { observations = try Self.perform(image, policy: .compatibleCPU, cancellation: cancellation) }
                    catch { try cancellation.check(); throw HoverLookupError.recognitionFailed }
                }
                try cancellation.check()
                let result = try consume(observations)
                try cancellation.check()
                return result
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
        catch { try cancellation.check(); throw HoverLookupError.recognitionFailed }
        try cancellation.check()
        return request.results ?? []
    }
}
