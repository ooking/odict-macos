import Foundation
import Vision
import XCTest
@testable import HoverLookupKit

final class OCRFailureTests: XCTestCase {
    func testTemporaryBundlesDoNotHideEmptyCommittedModels() throws {
        try withCache { root in
            // Reproduce more than 256 recursive entries, including populated
            // temporary models that must not count as healthy committed ones.
            for index in 0..<46 {
                let model = root.appendingPathComponent("revision/hash/model.tmp.\(index).bundle/H15S.bundle/main/main_ane/ane_mil_model")
                try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
                try Data([1]).write(to: model.appendingPathComponent("temporary.bin"))
            }
            for name in ["text", "orientation"] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent("revision/hash/\(name).bundle/H15S.bundle/main/main_ane"),
                    withIntermediateDirectories: true)
            }
            XCTAssertEqual(OCRCacheInspection.state(at: root), .emptyModelDirectory)
        }
    }

    func testTemporaryModelsAloneDoNotProveMissingCommittedModels() throws {
        try withCache { root in
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("revision/hash/model.tmp.1.bundle/H15S.bundle/main/main_ane"),
                withIntermediateDirectories: true)
            XCTAssertEqual(OCRCacheInspection.state(at: root), .unknown)
        }
    }

    func testPopulatedCommittedModelKeepsInspectionConservative() throws {
        try withCache { root in
            for name in ["empty", "populated"] {
                let model = root.appendingPathComponent("revision/hash/\(name).bundle/H15S.bundle/main/main_ane")
                try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
                if name == "populated" { try Data([1]).write(to: model.appendingPathComponent("model.anehash")) }
            }
            XCTAssertEqual(OCRCacheInspection.state(at: root), .unknown)
        }
    }

    private func withCache(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

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
