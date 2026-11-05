import AppKit
import CoreText
import os

/// Only a real missing-model failure starts repair. The child sees generated
/// fixtures, never the user's screenshot; it exits after warming system models.
final class OCRRecovery: @unchecked Sendable {
    static let argument = "--odict-repair-ocr-models"
    private let lock = NSLock()
    private var executable: URL?
    private var task: Task<Void, Never>?
    private var nextAttempt: TimeInterval = 0
    private let availability: OCRAvailability
    private let now: @Sendable () -> TimeInterval
    private let repair: @Sendable (URL) async -> Bool
    private let log = Logger(subsystem: "com.touchany.odict.mac", category: "OCRRecovery")

    init(availability: OCRAvailability,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         repair: @escaping @Sendable (URL) async -> Bool = {
             guard await OCRRepairProcess().run(executable: $0) else { return false }
             // A child exit alone is insufficient: the original runtime must
             // successfully read the regenerated resources too.
             return await ScreenTextService.verifyAfterRepair()
         }) {
        self.availability = availability
        self.now = now
        self.repair = repair
    }

    func enable(executable: URL) {
        lock.lock(); defer { lock.unlock() }
        self.executable = executable
    }

    func start(for failure: OCRFailure) -> OCRFailure {
        guard failure.kind == .modelResourcesUnavailable else { return failure }
        lock.lock(); defer { lock.unlock() }
        guard let executable else { return failure }
        if task != nil {
            var pending = failure
            pending.recoveryState = .inProgress
            availability.record(pending)
            return pending
        }
        guard now() >= nextAttempt else {
            var blocked = failure
            blocked.recoveryState = .failed
            availability.record(blocked)
            return blocked
        }
        nextAttempt = now() + 120
        var repairing = failure
        repairing.recoveryState = .inProgress
        availability.record(repairing)
        log.notice("event=repair.started")
        task = Task.detached(priority: .utility) { [self] in
            let success = await repair(executable)
            finish(success: success, failure: failure)
        }
        return repairing
    }

    private func finish(success: Bool, failure: OCRFailure) {
        lock.lock(); defer { lock.unlock() }
        if success { availability.recovered() }
        else {
            var failed = failure
            failed.recoveryState = .failed
            availability.record(failed)
        }
        task = nil
        log.notice("event=repair.finished success=\(success, privacy: .public)")
    }

    func stop() {
        lock.lock(); let active = task; executable = nil; lock.unlock()
        active?.cancel()
    }
}

/// One child, one timeout, no polling. Exit, cancellation and launch failure all
/// retire the continuation exactly once. No shell or user-controlled arguments.
final class OCRRepairProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: DispatchWorkItem?
    private var cancelled = false

    func run(executable: URL, arguments: [String] = [OCRRecovery.argument],
             timeoutSeconds: TimeInterval = 60) async -> Bool {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { pending in
                lock.lock()
                guard !cancelled else { lock.unlock(); pending.resume(returning: false); return }
                let child = Process()
                child.executableURL = executable
                child.arguments = arguments
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.nullDevice
                child.terminationHandler = { [weak self] child in
                    self?.complete(success: child.terminationReason == .exit && child.terminationStatus == 0)
                }
                continuation = pending
                process = child
                do {
                    try child.run()
                    let deadline = DispatchWorkItem { [weak self] in self?.cancel() }
                    timeout = deadline
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: deadline)
                    lock.unlock()
                } catch {
                    lock.unlock()
                    complete(success: false)
                }
            }
        }, onCancel: { self.cancel() })
    }

    private func complete(success: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        timeout?.cancel(); timeout = nil
        process = nil
        lock.unlock()
        pending?.resume(returning: success)
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let child = process
        lock.unlock()
        // The child contains no application state to save. Bound its lifetime
        // even if Vision is stuck in a synchronous system call.
        if let child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        complete(success: false)
    }
}

public extension ScreenTextService {
    /// Call only from the host's normal startup, never from the repair entry.
    static func enableAutomaticRecovery() {
        guard let executable = Bundle.main.executableURL else { return }
        recovery.enable(executable: executable)
    }

    static func stopAutomaticRecovery() { recovery.stop() }

    static var isRecoveryWorker: Bool {
        CommandLine.arguments.count == 2 && CommandLine.arguments[1] == OCRRecovery.argument
    }

    /// A fresh Vision runtime regenerates purgeable models. Does not remove,
    /// relocate or protect Apple's cache; both Chinese and Latin models warm up.
    static func runRecoveryWorker() async -> Bool {
        await verifyRecoveredModels()
    }
}

enum OCRModelProbe {
    static let fixtures = ["echo", "中文", "echo 中文"]
    static func image(_ value: String) -> CGImage? {
        guard let context = CGContext(data: nil, width: 640, height: 160, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 160))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, 32, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
        context.textPosition = CGPoint(x: 40, y: 80)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
