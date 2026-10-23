import XCTest
@testable import HoverLookupKit

final class HoverRequestGateTests: XCTestCase {
    @MainActor
    func testTimeoutRetainsSlotUntilProviderActuallyFinishes() async throws {
        let gate = HoverRequestGate<Int>()
        let provider = SuspendedProvider()
        defer { provider.finish() }
        let first = Task { try await gate.run(timeout: 1_000_000) { await provider.read() } }
        await provider.waitUntilStarted()
        do {
            _ = try await first.value
            XCTFail("Expected timeout")
        } catch HoverLookupError.timedOut {}

        do {
            _ = try await gate.run(timeout: 1_000_000_000) {
                XCTFail("A timed-out provider still owns the slot")
                return 2
            }
            XCTFail("Expected busy provider")
        } catch HoverLookupError.requestBusy {}

        provider.finish()
        await provider.waitUntilReturned()
        let next = try await gate.run(timeout: 1_000_000_000) { 3 }
        XCTAssertEqual(next, 3, "A late result must release the slot without replacing the timeout")
    }

    @MainActor
    func testCancellationReleasesCallerBeforeUncooperativeProvider() async throws {
        let gate = HoverRequestGate<Int>()
        let provider = SuspendedProvider()
        defer { provider.finish() }
        let first = Task { try await gate.run(timeout: 30_000_000_000) { await provider.read() } }
        await provider.waitUntilStarted()
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        do {
            _ = try await gate.run(timeout: 1_000_000_000) { 2 }
            XCTFail("Cancellation must not permit overlapping system calls")
        } catch HoverLookupError.requestBusy {}
        provider.finish()
        await provider.waitUntilReturned()
    }
}

@MainActor
private final class SuspendedProvider {
    private var pending: CheckedContinuation<Int, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var returned: CheckedContinuation<Void, Never>?
    private var didReturn = false

    func read() async -> Int {
        let value = await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
        didReturn = true
        returned?.resume()
        returned = nil
        return value
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        pending?.resume(returning: 1)
        pending = nil
    }

    func waitUntilReturned() async {
        if didReturn { return }
        await withCheckedContinuation { returned = $0 }
    }
}
