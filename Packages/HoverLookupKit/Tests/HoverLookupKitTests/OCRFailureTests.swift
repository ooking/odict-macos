import Foundation
import Vision
import XCTest
@testable import HoverLookupKit

final class OCRFailureTests: XCTestCase {
    func testMissingCacheAndImageErrorsAreNotInterchangeable() {
        let engine = NSError(domain: VNErrorDomain, code: VNErrorCode.internalError.rawValue)
        let missing = OCRFailure.classify(automatic: engine, compatibility: engine, cacheState: .emptyModelDirectory)
        XCTAssertEqual(missing.kind, .modelResourcesUnavailable)
        XCTAssertFalse(missing.allowsScreenshotRetry)

        let unknown = OCRFailure.classify(automatic: engine, compatibility: engine, cacheState: .unknown)
        XCTAssertEqual(unknown.kind, .engineUnavailable, "A generic Vision error does not prove cache deletion")
        let image = NSError(domain: VNErrorDomain, code: VNErrorCode.invalidImage.rawValue)
        let invalid = OCRFailure.classify(automatic: image, compatibility: image, cacheState: .emptyModelDirectory)
        XCTAssertEqual(invalid.kind, .invalidImage)
        XCTAssertTrue(invalid.allowsScreenshotRetry)
    }

    func testUnderlyingCodesArePreservedWithoutErrorDescriptions() {
        let inner = NSError(domain: "com.apple.TextRecognition", code: 13,
            userInfo: [NSLocalizedDescriptionKey: "private recognition input"])
        let outer = NSError(domain: VNErrorDomain, code: VNErrorCode.internalError.rawValue,
            userInfo: [NSUnderlyingErrorKey: inner])
        let failure = OCRFailure.classify(automatic: outer, compatibility: outer, cacheState: .unknown)
        XCTAssertEqual(failure.automaticErrors.count, 2)
        XCTAssertEqual(failure.automaticErrors.last?.domain, "com.apple.TextRecognition")
        XCTAssertEqual(failure.automaticErrors.last?.code, 13)
    }

    func testEngineCooldownExpiresAndSuccessClearsIt() throws {
        let clock = Clock()
        let availability = OCRAvailability(now: { clock.read() })
        let error = NSError(domain: VNErrorDomain, code: VNErrorCode.internalError.rawValue)
        let failure = OCRFailure.classify(automatic: error, compatibility: error, cacheState: .unknown)
        availability.record(failure)
        XCTAssertThrowsError(try availability.check())
        clock.advance(29)
        XCTAssertThrowsError(try availability.check())
        clock.advance(2)
        XCTAssertNoThrow(try availability.check(), "Expiry must allow recovery attempts without a timer")
        availability.record(failure)
        availability.recovered()
        XCTAssertNoThrow(try availability.check())
    }

    func testBadImageDoesNotPauseOtherImages() {
        let availability = OCRAvailability()
        let error = NSError(domain: VNErrorDomain, code: VNErrorCode.invalidImage.rawValue)
        availability.record(OCRFailure.classify(automatic: error, compatibility: error, cacheState: .unknown))
        XCTAssertNoThrow(try availability.check())
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
}
