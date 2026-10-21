import Foundation

/// Bridges synchronous system APIs without blocking the main actor. Cancellation
/// releases the caller immediately; an already-running system call may finish later.
final class BlockingWorkQueue: @unchecked Sendable {
    private let queue: DispatchQueue
    init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }

    func perform<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        let operation = PendingWork<Value>(body)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard operation.attach(continuation) else { return }
                queue.async {
                    guard let work = operation.takeBody() else { return }
                    operation.finish(Result { try autoreleasepool(invoking: work) })
                }
            }
        }, onCancel: { operation.cancel() })
    }
}

private final class PendingWork<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<Value, Error>?
    private var body: (@Sendable () throws -> Value)?
    init(_ body: @escaping @Sendable () throws -> Value) { self.body = body }
    func takeBody() -> (@Sendable () throws -> Value)? {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return nil }
        let work = body
        body = nil
        return work
    }

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
        body = nil // Retire queued images/work immediately, before the queue drains.
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: CancellationError())
    }
}
