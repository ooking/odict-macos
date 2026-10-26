import Foundation

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
    func set() { lock.lock(); storage = true; lock.unlock() }
}

private final class LocalProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let headers = path == "/advertised" ? ["Content-Length": "10000"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "/slow" { return }
        if path == "/chunks" {
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 100))
            client?.urlProtocol(self, didLoad: Data(repeating: 66, count: 100))
        } else { client?.urlProtocol(self, didLoad: Data("ok".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
private struct RuntimeServiceChecks {
    static func waitFor(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    @MainActor
    static func main() async throws {
        let worker = BlockingWorkQueue(label: "odict.fixture.blocking")
        let entered = Flag(), cancelled = Flag(), queuedRan = Flag()
        let release = DispatchSemaphore(value: 0)
        let blocked = Task {
            do { _ = try await worker.perform { entered.set(); release.wait(); return 1 } }
            catch is CancellationError { cancelled.set() }
        }
        let didEnter = await waitFor { entered.value }
        precondition(didEnter)
        let queued = Task { try await worker.perform { queuedRan.set(); return 2 } }
        blocked.cancel()
        queued.cancel()
        let cancelledBeforeSystemReturn = await waitFor { cancelled.value }
        release.signal()
        _ = await blocked.result
        _ = await queued.result
        _ = try await worker.perform { 3 }
        precondition(cancelledBeforeSystemReturn, "cancellation must release UI without waiting for the system call")
        precondition(!queuedRan.value, "cancelled queued work must not access the system")

        do { _ = try ServiceEndpoint("https://name:secret@fixture.invalid"); preconditionFailure("credentials must not be in the endpoint") }
        catch DictionaryError.configuration {}
        let encodedPath = try ServiceEndpoint("https://fixture.invalid/prefix%20one/").url(path: ["entries", "a/b"], query: [])
        precondition(encodedPath.absoluteString.contains("/prefix%20one/entries/a%2Fb"))
        let unicodePath = try ServiceEndpoint("https://fixture.invalid").url(path: ["entries", "中文 ?#%"], query: [])
        precondition(unicodePath.absoluteString.contains("%E4%B8%AD%E6%96%87%20%3F%23%25"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalProtocol.self]
        let bounded = HTTPTransport(maximumResponseBytes: 128, configuration: configuration)
        let good = try await bounded.data(for: URLRequest(url: URL(string: "https://fixture.invalid/good")!))
        precondition(String(data: good.0, encoding: .utf8) == "ok")
        for path in ["advertised", "chunks"] {
            do {
                _ = try await bounded.data(for: URLRequest(url: URL(string: "https://fixture.invalid/\(path)")!))
                preconditionFailure("oversized response must fail")
            } catch DictionaryError.responseTooLarge {}
        }
        let slow = Task { try await bounded.data(for: URLRequest(url: URL(string: "https://fixture.invalid/slow")!)) }
        try await Task.sleep(nanoseconds: 10_000_000)
        slow.cancel()
        do { _ = try await slow.value; preconditionFailure("cancelled HTTP request returned a result") }
        catch is CancellationError {}
        weak var weakTransport: HTTPTransport?
        do { let value = HTTPTransport(); weakTransport = value }
        precondition(weakTransport == nil, "URLSession delegate must not retain its owner")

        let rateLimit = RequestRateLimit()
        let response = HTTPURLResponse(url: URL(string: "https://fixture.invalid/a")!, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": "2"])!
        precondition(rateLimit.record(response) == "2")
        do { try rateLimit.check(response.url!); preconditionFailure("cooldown must prevent a new request") }
        catch DictionaryError.limited {}
        try rateLimit.check(URL(string: "https://other.invalid/a")!)
        let now = Date(timeIntervalSince1970: 1_000)
        let dated = HTTPURLResponse(url: response.url!, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "Thu, 01 Jan 1970 00:17:00 GMT"])!
        precondition(rateLimit.record(dated, now: now) == "20")

        let suite = "odict.runtime.fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["", "same", "SAME"] + (0..<30).map { "word\($0)" }, forKey: "recentWords")
        let history = RecentWordsStore(defaults: defaults)
        let recent = history.load()
        precondition(recent.count == 20 && recent.first == "same")

        print("PASS: prompt cancellation; queued work; encoded URLs; bounded HTTP; HTTP cancellation; transport lifetime; Retry-After; bounded history. No real network or Keychain used.")
    }
}
