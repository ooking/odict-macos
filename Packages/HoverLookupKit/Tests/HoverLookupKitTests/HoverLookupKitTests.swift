import AppKit
import XCTest
@testable import HoverLookupKit

final class HoverLookupKitTests: XCTestCase {
    func testDwellAndExtractionHaveDifferentMovementBudgets() {
        let rules = HoverStability()
        let origin = CGPoint(x: 100, y: 100)
        let moved = CGPoint(x: 107, y: 100)
        XCTAssertFalse(rules.accepts(origin: origin, current: moved, extracting: false))
        XCTAssertTrue(rules.accepts(origin: origin, current: moved, extracting: true))
        XCTAssertFalse(rules.accepts(origin: origin, current: CGPoint(x: 113, y: 100), extracting: true))
        let word = HoverWordHit(text: "first", anchor: CGRect(x: 90, y: 90, width: 14, height: 20))
        XCTAssertFalse(rules.accepts(word, at: moved), "Movement tolerance must not accept a neighboring word")
    }

    func testRepeatedWordsKeepTheirOwnRanges() {
        let text = "echo echo foo_bar don't"
        let words = HoverWords.ranges(in: text)
        XCTAssertEqual(words.map { String(text[$0]) }, ["echo", "echo", "foo", "bar", "don't"])
        XCTAssertNotEqual(words[0], words[1])
    }

    @MainActor
    func testAccessibilityHitDoesNotCreateOCR() async throws {
        let image = FixtureImage()
        var created = 0
        let pipeline = HoverLookupPipeline(text: FixtureText(hit: Self.hit), image: image, makeRecognizer: {
            created += 1
            return FixtureOCR()
        })
        let result = try await pipeline.word(in: Self.region, at: Self.point, allowsOCR: false)
        XCTAssertEqual(result?.text, "echo")
        XCTAssertEqual(image.calls, 0)
        XCTAssertEqual(created, 0)
    }

    @MainActor
    func testUnsafeTargetsNeverReachCapture() async {
        for failure in [HoverLookupError.secureInput, .excludedTarget, .accessibilityUnavailable,
                        .accessibilityHitTestFailed, .securityInspectionFailed, .securityDepthExceeded] {
            let image = FixtureImage()
            let pipeline = HoverLookupPipeline(text: FixtureText(failure: failure), image: image)
            do {
                _ = try await pipeline.word(in: Self.region, at: Self.point, allowsOCR: true)
                XCTFail("Unsafe target must fail closed")
            } catch {}
            XCTAssertEqual(image.calls, 0)
        }
    }

    @MainActor
    func testMissingPermissionStopsBeforeCapture() async {
        let image = FixtureImage()
        let pipeline = HoverLookupPipeline(text: FixtureText(), image: image)
        do {
            _ = try await pipeline.word(in: Self.region, at: Self.point, allowsOCR: false)
            XCTFail("Expected screen permission failure")
        } catch HoverLookupError.screenPermission {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(image.calls, 0)
    }

    @MainActor
    func testFallbackAndResourceRelease() async throws {
        let image = FixtureImage()
        var created = 0
        weak var retainedOCR: FixtureOCR?
        let pipeline = HoverLookupPipeline(text: FixtureText(), image: image, makeRecognizer: {
            created += 1
            let reader = FixtureOCR()
            retainedOCR = reader
            return reader
        })
        var stages: [HoverDiagnostic.Stage] = []
        pipeline.onDiagnostic = { if $0.outcome == .started { stages.append($0.stage) } }
        _ = try await pipeline.word(in: Self.region, at: Self.point, allowsOCR: true)
        _ = try await pipeline.word(in: Self.region, at: Self.point, allowsOCR: true)
        XCTAssertEqual(created, 1)
        XCTAssertEqual(image.calls, 2)
        XCTAssertEqual(stages, [.accessibility, .capture, .recognition, .accessibility, .capture, .recognition])
        XCTAssertNotNil(retainedOCR)
        pipeline.releaseResources()
        XCTAssertNil(retainedOCR)
    }

    @MainActor
    func testCancelledAccessibilityCannotStartFallback() async {
        let image = FixtureImage()
        let text = SuspendedText()
        let pipeline = HoverLookupPipeline(text: text, image: image)
        let task = Task { try await pipeline.word(in: Self.region, at: Self.point, allowsOCR: true) }
        // Wait for the injected provider, without timers or real AX calls.
        await text.waitUntilStarted()
        task.cancel()
        await text.finish()
        do { _ = try await task.value; XCTFail("Cancelled request returned a result") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(image.calls, 0)
    }

    private static let point = CGPoint(x: 100, y: 100)
    private static let hit = HoverWordHit(text: "echo", anchor: CGRect(x: 90, y: 90, width: 40, height: 20))
    private static let region = ScreenRegion(rect: CGRect(x: 0, y: 0, width: 640, height: 160),
        displayID: 0, screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2, primaryTop: 900)
}

private struct FixtureText: HoverTextReading {
    var hit: HoverWordHit? = nil
    var failure: HoverLookupError? = nil
    func word(at point: CGPoint, primaryTop: CGFloat) async throws -> HoverWordHit? {
        if let failure { throw failure }
        return hit
    }
}

private actor SuspendedText: HoverTextReading {
    private var continuation: CheckedContinuation<HoverWordHit?, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func word(at point: CGPoint, primaryTop: CGFloat) async throws -> HoverWordHit? {
        await withCheckedContinuation {
            continuation = $0
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}

private final class FixtureImage: ScreenImageCapturing {
    var calls = 0
    func capture(_ region: ScreenRegion) async throws -> CGImage {
        calls += 1
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}

private final class FixtureOCR: HoverWordRecognizing {
    func recognizeWord(_ image: CGImage, region: CGRect, point: CGPoint) async throws -> HoverWordHit? {
        HoverWordHit(text: "echo", anchor: CGRect(x: 90, y: 90, width: 40, height: 20))
    }
}
