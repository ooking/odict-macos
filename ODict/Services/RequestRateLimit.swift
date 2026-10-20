import Foundation

/// A single endpoint's cooldown, measured with a monotonic clock. No retry timer,
/// sleeping task or unbounded host cache is kept alive.
final class RequestRateLimit: @unchecked Sendable {
    private let lock = NSLock()
    private var origin: String?
    private var deadline: TimeInterval = 0

    func check(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        if origin == Self.origin(url), remaining > 0 {
            throw DictionaryError.limited(String(Int(ceil(remaining))))
        }
    }

    @discardableResult
    func record(_ response: HTTPURLResponse, now: Date = Date()) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        let seconds: TimeInterval
        if let value = Double(header), value.isFinite, value >= 0 { seconds = value }
        else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
            guard let date = formatter.date(from: header) else { return nil }
            seconds = max(0, date.timeIntervalSince(now))
        }
        // Keep conversions and arithmetic bounded even for a malformed server header.
        let bounded = min(seconds, 365 * 24 * 60 * 60)
        lock.lock()
        origin = response.url.map(Self.origin)
        deadline = ProcessInfo.processInfo.systemUptime + bounded
        lock.unlock()
        return String(Int(ceil(bounded)))
    }

    private static func origin(_ url: URL) -> String { "\(url.scheme ?? "")://\(url.host ?? ""):\(url.port ?? 443)" }
}
