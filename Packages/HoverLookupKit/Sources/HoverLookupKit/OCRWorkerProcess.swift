import AppKit
import Darwin

/// One process for hover, manual OCR and recovery verification together. The
/// serial worker keeps its slot until the old child has actually exited, even
/// when a cancelled caller has already returned. No images or results cached.
final class OCRWorkerRuntime: @unchecked Sendable {
    static let shared = OCRWorkerRuntime()
    private let lock = NSLock()
    private let worker = BlockingWorkQueue(label: "HoverLookupKit.ocr-process")
    private var executable: URL?
    private var configured = false
    private var active: OCRWorkerProcess?

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return configured
    }

    func enable(executable: URL) {
        lock.lock(); defer { lock.unlock() }
        self.executable = executable
        configured = true
    }

    func stop() {
        lock.lock()
        executable = nil
        let child = active
        lock.unlock()
        child?.cancel()
    }

    func run(_ request: OCRWorkerRequest, image: CGImage? = nil) async throws -> OCRWorkerResponse {
        let child = OCRWorkerProcess()
        return try await withTaskCancellationHandler(operation: {
            try await worker.perform { [self] in
                let executable = try install(child)
                defer { retire(child) }
                return try child.run(executable: executable, request: request, image: image)
            }
        }, onCancel: { child.cancel() })
    }

    private func install(_ child: OCRWorkerProcess) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard let executable else { throw CancellationError() }
        active = child
        return executable
    }

    private func retire(_ child: OCRWorkerProcess) {
        lock.lock(); defer { lock.unlock() }
        if active === child { active = nil }
    }
}

/// Synchronous IPC stays off the main actor. Cancellation kills only this
/// state-free child and shuts down its socket, waking a blocked read/write.
/// A hard deadline also covers IPC and a stuck Vision system call after launch.
final class OCRWorkerProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var descriptor: Int32 = -1
    private var cancelled = false
    private var timedOut = false

    func run(executable: URL, request: OCRWorkerRequest, image: CGImage?,
             timeoutSeconds: TimeInterval = 60,
             arguments: [String] = [ScreenTextService.workerArgument]) throws -> OCRWorkerResponse {
        try checkCancellation()
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw HoverLookupError.recognitionFailed }
        let parent = sockets[0]
        let inherited = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
        defer { try? inherited.close() }
        defer { close(parent) }
        try OCRWorkerChannel.configure(parent)
        try OCRWorkerChannel.configure(inherited.fileDescriptor)

        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.standardInput = inherited
        child.standardOutput = inherited
        child.standardError = FileHandle.nullDevice
        // Do not inherit Xcode injection/debugging state or arbitrary secrets.
        child.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                             "TMPDIR": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        child.qualityOfService = .userInitiated
        let deadline = DispatchWorkItem { [weak self] in self?.cancel(timedOut: true) }
        var launched = false
        defer {
            deadline.cancel()
            // Keep the serial slot and process identity until it is reaped.
            if launched {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
            lock.lock()
            process = nil
            descriptor = -1
            lock.unlock()
        }

        lock.lock()
        guard !cancelled else { lock.unlock(); throw CancellationError() }
        do {
            try child.run()
            launched = true
            process = child
            descriptor = parent
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: deadline)
            lock.unlock()
        } catch {
            lock.unlock()
            throw HoverLookupError.recognitionFailed
        }
        try? inherited.close() // Only the child's stdin/stdout retain this end.
        do {
            try OCRWorkerChannel.sendMessage(request, to: parent, limit: OCRWorkerChannel.requestLimit)
            if request.mode != .verify {
                guard let image else { throw HoverLookupError.captureFailed }
                // End the pixel buffer's lifetime before reading/decoding a result.
                try autoreleasepool {
                    let pixels = try request.pixels(from: image)
                    try checkCancellation()
                    try pixels.withUnsafeBytes { try OCRWorkerChannel.send($0, to: parent) }
                }
            }
            shutdown(parent, SHUT_WR)
            let response = try OCRWorkerChannel.receiveMessage(OCRWorkerResponse.self, from: parent,
                                                               limit: OCRWorkerChannel.responseLimit)
            // Child closes stdout only when exiting. Bound shutdown by the same
            // deadline; do not deliver a result while the model is still resident.
            var byte: UInt8 = 0
            var end: Int
            repeat { end = recv(parent, &byte, 1, 0) } while end < 0 && errno == EINTR
            try checkCancellation()
            guard end == 0 else { throw HoverLookupError.recognitionFailed }
            child.waitUntilExit()
            try checkCancellation()
            guard child.terminationReason == .exit, child.terminationStatus == 0 else {
                throw HoverLookupError.recognitionFailed
            }
            return response
        } catch {
            try checkCancellation()
            throw error
        }
    }

    func cancel(timedOut: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        self.timedOut = self.timedOut || timedOut
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
    }

    private func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if timedOut { throw HoverLookupError.timedOut }
        if cancelled { throw CancellationError() }
    }
}
