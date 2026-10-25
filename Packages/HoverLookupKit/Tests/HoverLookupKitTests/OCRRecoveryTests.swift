import Foundation
import Vision
import XCTest
@testable import HoverLookupKit

final class OCRRecoveryTests: XCTestCase {
    private func failure(_ cache: OCRFailure.CacheState = .emptyModelDirectory) -> OCRFailure {
        let error = NSError(domain: VNErrorDomain, code: VNErrorCode.internalError.rawValue)
        return OCRFailure.classify(automatic: error, compatibility: error, cacheState: cache)
    }

    func testSingleRepairClearsFailureWithoutChangingOriginalError() async throws {
        let started = expectation(description: "repair started")
        let availability = OCRAvailability()
        let gate = RepairGate()
        let recovery = OCRRecovery(availability: availability, repair: { _ in
            started.fulfill()
            return await gate.wait()
        })
        recovery.enable(executable: URL(fileURLWithPath: "/unused/test-host"))
        let original = failure()
        let repairing = recovery.start(for: original)
        XCTAssertTrue(repairing.isRecovering)
        XCTAssertFalse(original.isRecovering)
        XCTAssertThrowsError(try availability.check()) { error in
            XCTAssertTrue((error as? OCRFailure)?.isRecovering == true)
        }
        // A second request must not create another child.
        XCTAssertTrue(recovery.start(for: original).isRecovering)
        await fulfillment(of: [started], timeout: 2)
        await gate.finish(true)
        let completed = expectation(description: "recovery completed")
        Task {
            for _ in 0..<1000 {
                if (try? availability.check()) != nil { completed.fulfill(); return }
                await Task.yield()
            }
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertNoThrow(try availability.check())
        XCTAssertFalse(recovery.start(for: original).isRecovering, "Retry cooldown prevents a repair storm")
    }

    func testUnknownEngineFailureDoesNotLaunchRepair() {
        let recovery = OCRRecovery(availability: OCRAvailability(), repair: { _ in
            XCTFail("An unknown engine error must not trigger model repair")
            return false
        })
        recovery.enable(executable: URL(fileURLWithPath: "/unused/test-host"))
        XCTAssertFalse(recovery.start(for: failure(.unknown)).isRecovering)
    }

    func testUnconfiguredHostCannotSpawnItself() {
        let recovery = OCRRecovery(availability: OCRAvailability())
        XCTAssertFalse(recovery.start(for: failure()).isRecovering)
    }

    func testChildExitAndLaunchFailure() async {
        let success = await OCRRepairProcess().run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        XCTAssertTrue(success)
        let failure = await OCRRepairProcess().run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
        XCTAssertFalse(failure)
        let missing = await OCRRepairProcess().run(executable: URL(fileURLWithPath: "/nonexistent/odict-worker"))
        XCTAssertFalse(missing)
    }

    func testTimeoutStopsChildAndCompletes() async {
        let start = ProcessInfo.processInfo.systemUptime
        let success = await OCRRepairProcess().run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                  arguments: ["30"], timeoutSeconds: 0.05)
        XCTAssertFalse(success)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
    }

    func testCancellationBeforeLaunchCompletes() async {
        let task = Task {
            await OCRRepairProcess().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        }
        task.cancel()
        let success = await task.value
        XCTAssertFalse(success)
    }
}

private actor RepairGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ value: Bool) {
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}
