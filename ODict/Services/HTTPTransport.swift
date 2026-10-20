import Foundation

protocol HTTPTransporting {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession owns a separate delegate, never its client. All buffers and the task
/// registry live on one native delegate queue, with a strict per-response limit.
final class HTTPTransport: HTTPTransporting {
    private let session: URLSession
    private let delegate: ResponseDelegate

    init(maximumResponseBytes: Int = 4 * 1024 * 1024, configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        delegate = ResponseDelegate(limit: maximumResponseBytes)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    deinit { session.invalidateAndCancel() }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let pending = PendingRequest()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                // Register before resuming so an immediate completion cannot be lost.
                delegate.register(task: task, pending: pending)
                pending.start(task: task, continuation: continuation)
            }
        }, onCancel: { pending.cancel() })
    }
}

private final class PendingRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    // Accessed only on the serial URLSession delegate queue.
    var response: HTTPURLResponse?
    var buffer = Data()

    func start(task: URLSessionDataTask, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            // A cancelled suspended task still delivers didComplete and clears the registry.
            task.cancel()
            return
        }
        self.task = task
        self.continuation = continuation
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = task
        let pending = continuation
        continuation = nil
        task = nil
        lock.unlock()
        current?.cancel()
        pending?.resume(throwing: CancellationError())
    }

    func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        task = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

private final class ResponseDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Int: PendingRequest] = [:]
    private let limit: Int
    init(limit: Int) { self.limit = max(1, limit) }

    func register(task: URLSessionDataTask, pending value: PendingRequest) {
        lock.lock(); pending[task.taskIdentifier] = value; lock.unlock()
    }

    private func request(_ task: URLSessionTask, remove: Bool = false) -> PendingRequest? {
        lock.lock(); defer { lock.unlock() }
        return remove ? pending.removeValue(forKey: task.taskIdentifier) : pending[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let value = request(dataTask), let http = response as? HTTPURLResponse else {
            request(dataTask, remove: true)?.finish(.failure(DictionaryError.invalidResponse))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            request(dataTask, remove: true)?.finish(.failure(DictionaryError.responseTooLarge))
            completionHandler(.cancel)
            return
        }
        value.response = http
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let value = request(dataTask) else { return }
        guard data.count <= limit - value.buffer.count else {
            request(dataTask, remove: true)?.finish(.failure(DictionaryError.responseTooLarge))
            dataTask.cancel()
            return
        }
        value.buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let value = request(task, remove: true) else { return }
        if let error { value.finish(.failure(error)) }
        else if let response = value.response { value.finish(.success((value.buffer, response))) }
        else { value.finish(.failure(DictionaryError.invalidResponse)) }
    }
}
