import Foundation

/// Bridges synchronous system APIs without blocking the main actor. Cancellation
/// releases the caller immediately; an already-running system call may finish later.
final class BlockingWorkQueue: @unchecked Sendable {
    private let queue: DispatchQueue
    init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }

    func perform<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        let operation = PendingWork<Value>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard operation.attach(continuation) else { return }
                queue.async {
                    guard !operation.isCancelled else { return }
                    operation.finish(Result { try autoreleasepool(invoking: body) })
                }
            }
        }, onCancel: { operation.cancel() })
    }
}

private final class PendingWork<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<Value, Error>?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func attach(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: CancellationError())
    }
}
