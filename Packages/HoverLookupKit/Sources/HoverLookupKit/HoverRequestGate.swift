import Foundation

/// One outstanding provider call per stage, including calls whose callers have
/// already timed out. A deadline releases the caller, not the provider's slot:
/// some system APIs do not finish immediately when their Task is cancelled.
@MainActor
final class HoverRequestGate<Value> {
    private var active: HoverPendingRequest<Value>?

    func run(timeout: UInt64, operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard active == nil else { throw HoverLookupError.requestBusy }
        let request = HoverPendingRequest<Value>()
        active = request
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                request.start(continuation, timeout: timeout, operation: operation) { [weak self] in
                    self?.active = nil
                }
                if Task.isCancelled { request.cancel() }
            }
        }, onCancel: {
            Task { @MainActor in request.cancel() }
        })
    }
}

@MainActor
private final class HoverPendingRequest<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    func start(_ continuation: CheckedContinuation<Value, Error>, timeout: UInt64,
               operation: @escaping @MainActor () async throws -> Value,
               finished: @escaping @MainActor () -> Void) {
        self.continuation = continuation
        work = Task {
            let result: Result<Value, Error>
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
            resolve(result)
            work = nil
            finished()
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: timeout) } catch { return }
            guard let self else { return }
            self.work?.cancel()
            self.resolve(.failure(HoverLookupError.timedOut))
        }
    }

    func cancel() {
        work?.cancel()
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<Value, Error>) {
        deadline?.cancel()
        deadline = nil
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
