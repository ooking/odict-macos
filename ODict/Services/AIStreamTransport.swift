import Foundation

enum AIHTTPStreamEvent { case response(HTTPURLResponse), data(Data) }
protocol AIStreamingTransporting {
    func events(for request: URLRequest) -> AsyncThrowingStream<AIHTTPStreamEvent, Error>
}

/// One bounded, cancellable request. Its delegate never retains the transport owner.
final class AIStreamTransport: AIStreamingTransporting {
    private let session: URLSession
    private let delegate = AIStreamDelegate()
    init(timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 10
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }
    func events(for request: URLRequest) -> AsyncThrowingStream<AIHTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = session.dataTask(with: request)
            continuation.onTermination = { [weak delegate] _ in delegate?.cancel() }
            delegate.start(task, continuation: continuation)
        }
    }
    deinit { session.invalidateAndCancel() }
}

private final class AIStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: AsyncThrowingStream<AIHTTPStreamEvent, Error>.Continuation?
    private var total = 0
    private let limit = 1024 * 1024
    func start(_ task: URLSessionDataTask, continuation: AsyncThrowingStream<AIHTTPStreamEvent, Error>.Continuation) {
        lock.lock(); self.task = task; self.continuation = continuation; lock.unlock()
        task.resume()
    }
    func cancel() {
        lock.lock(); let task = task; lock.unlock()
        task?.cancel()
        finish(CancellationError())
    }
    private func finish(_ error: Error?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil; task = nil
        lock.unlock()
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(AIError.invalidResponse); completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            finish(AIError.responseTooLarge); completionHandler(.cancel); return
        }
        lock.lock(); let continuation = continuation; lock.unlock()
        continuation?.yield(.response(http))
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // These byte counters run only on the serial delegate queue. Even an unconsumed stream is bounded.
        guard data.count <= limit - total else {
            finish(AIError.responseTooLarge); dataTask.cancel(); return
        }
        total += data.count
        lock.lock(); let continuation = continuation; lock.unlock()
        continuation?.yield(.data(data))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(error) }
}
