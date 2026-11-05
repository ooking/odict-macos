import AppKit
import Darwin
import XCTest
@testable import HoverLookupKit

final class OCRWorkerTests: XCTestCase {
    private let verification = OCRWorkerRequest(mode: .verify, width: 1, height: 1,
        maximumCount: 1, region: nil, point: nil)

    func testPixelTransportPreservesRowsAndChannels() throws {
        // Asymmetric rows/channels catch flips and premultiplication mistakes
        // which would otherwise break OCR geometry after process isolation.
        let pixels = Data([0, 0, 255, 255, 0, 255, 0, 255,
                           255, 0, 0, 255, 255, 255, 255, 255])
        let request = OCRWorkerRequest(mode: .text, width: 2, height: 2,
            maximumCount: 4000, region: nil, point: nil)
        let image = try request.image(from: pixels)
        XCTAssertEqual(try request.pixels(from: image), pixels)
    }

    func testRejectsOversizedOrInvalidImageBeforeAllocating() {
        for width in [0, -1, 4097, Int.max] {
            let request = OCRWorkerRequest(mode: .text, width: width, height: 1,
                maximumCount: 4000, region: nil, point: nil)
            XCTAssertThrowsError(try request.pixelCount)
        }
        let request = OCRWorkerRequest(mode: .word, width: 1, height: 1,
            maximumCount: 255, region: CGRect(x: 0, y: 0, width: 100, height: 20),
            point: CGPoint(x: 101, y: 10))
        XCTAssertThrowsError(try request.pixelCount)
    }

    func testChannelRejectsOversizedFrameAndPrematureEOF() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        try OCRWorkerChannel.configure(pair[0])
        try OCRWorkerChannel.configure(pair[1])
        let prefix = Data([0x7f, 0xff, 0xff, 0xff])
        try prefix.withUnsafeBytes { try OCRWorkerChannel.send($0, to: pair[0]) }
        XCTAssertThrowsError(try OCRWorkerChannel.receiveMessage(OCRWorkerResponse.self,
            from: pair[1], limit: OCRWorkerChannel.responseLimit))
        shutdown(pair[0], SHUT_WR)
        XCTAssertThrowsError(try OCRWorkerChannel.receive(count: 1, from: pair[1]))
    }

    func testClosedPeerDoesNotTerminateSender() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        try OCRWorkerChannel.configure(pair[0])
        shutdown(pair[1], SHUT_RDWR)
        XCTAssertThrowsError(try OCRWorkerChannel.sendMessage(verification,
            to: pair[0], limit: OCRWorkerChannel.requestLimit))
    }

    func testResponseRoundTripOverLocalChannel() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        try OCRWorkerChannel.configure(pair[0])
        let expected = OCRWorkerResponse(status: .success, text: "echo 中文",
            anchor: CGRect(x: -100, y: 50, width: 40, height: 20))
        try OCRWorkerChannel.sendMessage(expected, to: pair[0], limit: OCRWorkerChannel.responseLimit)
        let actual = try OCRWorkerChannel.receiveMessage(OCRWorkerResponse.self,
            from: pair[1], limit: OCRWorkerChannel.responseLimit)
        XCTAssertEqual(actual.status, expected.status)
        XCTAssertEqual(actual.text, expected.text)
        XCTAssertEqual(actual.anchor, expected.anchor)
    }

    func testFailureTransportContainsOnlyStructuredCodes() throws {
        let underlying = NSError(domain: "com.apple.TextRecognition", code: 13,
            userInfo: [NSLocalizedDescriptionKey: "private screenshot text"])
        let failure = OCRFailure.classify(automatic: underlying, compatibility: underlying, cacheState: .unknown)
        let encoded = try JSONEncoder().encode(OCRWorkerResponse(status: .failure, failure: failure))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private screenshot text"))
        let decoded = try JSONDecoder().decode(OCRWorkerResponse.self, from: encoded)
        XCTAssertEqual(decoded.failure?.automaticErrors.first?.code, 13)
        XCTAssertEqual(decoded.failure?.kind, failure.kind)
    }

    func testPrelaunchCancellationAndMissingExecutable() {
        let cancelled = OCRWorkerProcess()
        cancelled.cancel()
        XCTAssertThrowsError(try cancelled.run(executable: URL(fileURLWithPath: "/usr/bin/true"),
            request: verification, image: nil)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try OCRWorkerProcess().run(executable: URL(fileURLWithPath: "/nonexistent/odict-worker"),
            request: verification, image: nil))
    }

    func testEarlyExitCannotDeliverResultOrRaiseSIGPIPE() async {
        let request = verification
        let succeeded = await Task.detached {
            do {
                _ = try OCRWorkerProcess().run(executable: URL(fileURLWithPath: "/usr/bin/true"),
                    request: request, image: nil, arguments: [])
                return true
            } catch { return false }
        }.value
        XCTAssertFalse(succeeded)
    }

    func testDeadlineReapsUnresponsiveChild() async {
        let request = verification
        let start = ProcessInfo.processInfo.systemUptime
        let timedOut = await Task.detached {
            do {
                _ = try OCRWorkerProcess().run(executable: URL(fileURLWithPath: "/bin/sleep"),
                    request: request, image: nil, timeoutSeconds: 0.05, arguments: ["30"])
                return false
            } catch HoverLookupError.timedOut { return true }
            catch { return false }
        }.value
        XCTAssertTrue(timedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
    }
}
