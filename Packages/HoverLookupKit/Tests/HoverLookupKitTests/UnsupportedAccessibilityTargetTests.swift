import AppKit
import XCTest
@testable import HoverLookupKit

final class UnsupportedAccessibilityTargetTests: XCTestCase {
    func testOnlyFrontmostUncoveredWindowCanOwnFallback() {
        let target = window(pid: 42)
        XCTAssertTrue(UnsupportedAccessibilityTarget.ownsPoint(.zero, pid: 42, windows: [target]))
        XCTAssertFalse(UnsupportedAccessibilityTarget.ownsPoint(.zero, pid: 43, windows: [target]))
        XCTAssertFalse(UnsupportedAccessibilityTarget.ownsPoint(.zero, pid: 42,
            windows: [window(pid: 43), target]), "A different app covering the point must block capture")
        XCTAssertTrue(UnsupportedAccessibilityTarget.ownsPoint(.zero, pid: 42,
            windows: [window(pid: 42, layer: 3), target]), "Foreground-app floating windows are valid")
        XCTAssertFalse(UnsupportedAccessibilityTarget.ownsPoint(.zero, pid: 42,
            windows: [window(pid: 43, layer: 3), target]), "Another app's overlay must block capture")
        XCTAssertTrue(UnsupportedAccessibilityTarget.ownsPoint(.zero, pid: 42,
            windows: [window(pid: 43, alpha: 0), target]))
        XCTAssertFalse(UnsupportedAccessibilityTarget.ownsPoint(CGPoint(x: 200, y: 200),
            pid: 42, windows: [target]))
    }

    func testOnlyVerifiedFullScreenDockBackdropMayBeSkipped() {
        let screen = CGRect(x: -10, y: -10, width: 100, height: 100)
        let layer = Int(CGWindowLevelForKey(.dockWindow))
        let backdrop = window(pid: 7, layer: layer)
        let target = window(pid: 42)
        XCTAssertTrue(UnsupportedAccessibilityTarget.ownsPoint(.zero, pid: 42,
            windows: [backdrop, target], dockPID: 7, screenBounds: screen))
        XCTAssertFalse(UnsupportedAccessibilityTarget.ownsPoint(.zero, pid: 42,
            windows: [backdrop, target], dockPID: 8, screenBounds: screen))
        XCTAssertFalse(UnsupportedAccessibilityTarget.ownsPoint(.zero, pid: 42,
            windows: [window(pid: 7, layer: 3), target], dockPID: 7, screenBounds: screen))
        var strip = backdrop
        strip[kCGWindowBounds as String] = CGRect(x: -10, y: -10, width: 100, height: 15).dictionaryRepresentation
        XCTAssertFalse(UnsupportedAccessibilityTarget.ownsPoint(.zero, pid: 42,
            windows: [strip, target], dockPID: 7, screenBounds: screen), "The actual Dock must still block capture")
        XCTAssertFalse(UnsupportedAccessibilityTarget.ownsPoint(.zero, pid: 42,
            windows: [backdrop, window(pid: 43)], dockPID: 7, screenBounds: screen),
            "Skipping a system backdrop must not bypass foreground ownership")
    }

    func testPointerWindowMayDifferFromKeyboardForeground() throws {
        let windows = [window(pid: 42)]
        let target = try UnsupportedAccessibilityTarget.targetPID(at: .zero, windows: windows, foregroundPID: 43)
        XCTAssertEqual(target, 42, "Visible background windows must support hover OCR without activation")
        XCTAssertNoThrow(try UnsupportedAccessibilityTarget.checkPoint(.zero, pid: target, windows: windows))
        XCTAssertThrowsError(try UnsupportedAccessibilityTarget.checkPoint(.zero, pid: target,
            windows: [window(pid: 43), window(pid: 42)]), "A new occluding window must invalidate the target")
    }

    func testWindowInspectionIsBounded() {
        let transparent = window(pid: 43, alpha: 0)
        let windows = Array(repeating: transparent, count: 256) + [window(pid: 42)]
        XCTAssertFalse(UnsupportedAccessibilityTarget.ownsPoint(.zero, pid: 42, windows: windows))
    }

    @MainActor
    func testUnsupportedErrorAloneCannotAuthorizeScreenshot() async {
        for code in [Int32(-25208), -25204, -25211] {
            let image = UnexpectedCapture()
            let pipeline = HoverLookupPipeline(text: FailedText(code: code), image: image)
            do {
                _ = try await pipeline.word(in: region, at: .zero, allowsOCR: true)
                XCTFail("Unvalidated error must not authorize OCR")
            } catch {}
            XCTAssertEqual(image.calls, 0)
        }
    }

    @MainActor
    func testApprovedFallbackStillRequiresScreenPermissionAndLogsItsCause() async {
        let image = UnexpectedCapture()
        let pipeline = HoverLookupPipeline(text: ApprovedText(), image: image)
        var fallback: HoverDiagnostic?
        pipeline.onDiagnostic = { if $0.outcome == .fallback { fallback = $0 } }
        do {
            _ = try await pipeline.word(in: region, at: .zero, allowsOCR: false)
            XCTFail("Screen permission is required")
        } catch HoverLookupError.screenPermission {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(image.calls, 0)
        XCTAssertEqual(fallback?.accessibilityOperation, .elementAtPosition)
        XCTAssertEqual(fallback?.systemCode, -25208)
        XCTAssertEqual(fallback?.reason, .unsupportedInterface)
    }

    private func window(pid: Int32, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
        [kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowLayer as String: NSNumber(value: layer),
         kCGWindowAlpha as String: NSNumber(value: alpha),
         kCGWindowBounds as String: CGRect(x: -10, y: -10, width: 100, height: 100).dictionaryRepresentation]
    }

    private var region: ScreenRegion {
        ScreenRegion(rect: CGRect(x: 0, y: 0, width: 100, height: 100), displayID: 0,
            screenFrame: CGRect(x: 0, y: 0, width: 500, height: 500), scale: 1, primaryTop: 500)
    }
}

private struct FailedText: HoverTextReading {
    let code: Int32
    func word(at point: CGPoint, primaryTop: CGFloat) async throws -> HoverWordHit? {
        throw HoverLookupError.accessibilityCallFailed(operation: .elementAtPosition, code: code)
    }
}

private struct ApprovedText: HoverTextReading {
    func word(at point: CGPoint, primaryTop: CGFloat) async throws -> HoverWordHit? {
        throw AccessibilityOCRFallback(operation: .elementAtPosition, code: -25208, targetPID: 42)
    }
}

private final class UnexpectedCapture: ScreenImageCapturing {
    var calls = 0
    func capture(_ region: ScreenRegion) async throws -> CGImage {
        calls += 1
        throw HoverLookupError.captureFailed
    }
}
