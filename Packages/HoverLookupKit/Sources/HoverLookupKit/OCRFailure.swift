import Foundation
import Vision

public struct OCRFailure: Error, Sendable {
    public enum Kind: String, Sendable {
        case modelResourcesUnavailable, engineUnavailable, invalidImage, unsupportedConfiguration, insufficientMemory
    }
    public enum CacheState: String, Sendable { case notInspected, emptyModelDirectory, unknown }
    public enum RecoveryState: Sendable { case notAttempted, inProgress, failed }
    public struct SystemError: Sendable {
        public let domain: String
        public let code: Int
    }
    public let kind: Kind
    public let cacheState: CacheState
    public let automaticErrors: [SystemError]
    public let compatibilityErrors: [SystemError]
    public internal(set) var recoveryState: RecoveryState = .notAttempted
    public var isRecovering: Bool { recoveryState == .inProgress }

    public var allowsScreenshotRetry: Bool { kind == .invalidImage }

    static func classify(automatic: Error, compatibility: Error,
                         cacheState: CacheState) -> OCRFailure {
        let first = chain(automatic), second = chain(compatibility)
        let errors = first + second
        let kind: Kind
        if errors.contains(where: { $0.domain == VNErrorDomain && $0.code == VNErrorCode.outOfMemory.rawValue }) {
            kind = .insufficientMemory
        } else if errors.contains(where: { $0.domain == VNErrorDomain &&
            [VNErrorCode.invalidImage.rawValue, VNErrorCode.invalidFormat.rawValue].contains($0.code) }) {
            kind = .invalidImage
        } else if errors.contains(where: { $0.domain == VNErrorDomain &&
            [VNErrorCode.unsupportedRevision.rawValue, VNErrorCode.unsupportedRequest.rawValue,
             VNErrorCode.invalidOption.rawValue].contains($0.code) }) {
            kind = .unsupportedConfiguration
        } else if cacheState == .emptyModelDirectory {
            // This reports observed missing cache files, not who removed them.
            kind = .modelResourcesUnavailable
        } else {
            kind = .engineUnavailable
        }
        return OCRFailure(kind: kind, cacheState: cacheState,
            automaticErrors: first, compatibilityErrors: second)
    }

    private static func chain(_ error: Error) -> [SystemError] {
        var next: NSError? = error as NSError
        var result: [SystemError] = []
        for _ in 0..<6 {
            guard let current = next else { break }
            let domain = current.domain
            let safeDomain = domain.count <= 160 && domain.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || $0 == 46 || $0 == 45 || $0 == 95
            } ? domain : "other"
            result.append(SystemError(domain: safeDomain, code: current.code))
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }
}

/// Read metadata only after OCR has actually failed. An absent cache before a
/// first request is normal and must never prevent model initialization.
enum OCRCacheInspection {
    static func state(fileManager: FileManager = .default) -> OCRFailure.CacheState {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return .unknown }
        let root = caches.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
        guard let entries = fileManager.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return .unknown }
        var inspected = 0
        var empty = 0
        var exhausted = false
        for _ in 0..<256 {
            guard let url = entries.nextObject() as? URL else { exhausted = true; break }
            guard let metadata = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { continue }
            if metadata.isSymbolicLink == true { entries.skipDescendants(); continue }
            guard url.lastPathComponent == "main_ane", metadata.isDirectory == true else { continue }
            inspected += 1
            guard let children = try? fileManager.contentsOfDirectory(at: url,
                includingPropertiesForKeys: nil) else { return .unknown }
            if children.isEmpty { empty += 1 }
            else { return .unknown }
        }
        return exhausted && inspected > 0 && empty == inspected ? .emptyModelDirectory : .unknown
    }
}

/// Bounded failure state shared by hover and manual OCR, without a timer or
/// background polling. Expiry permits a fresh attempt; it is not a repair claim.
final class OCRAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: OCRFailure?
    private var retryAfter: TimeInterval = 0
    private let now: @Sendable () -> TimeInterval
    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if let failure, now() < retryAfter { throw failure }
    }
    func record(_ failure: OCRFailure) {
        guard !failure.allowsScreenshotRetry else { return }
        lock.lock(); defer { lock.unlock() }
        self.failure = failure
        retryAfter = failure.isRecovering ? .infinity : now() + 30
    }
    func recovered() { lock.lock(); failure = nil; retryAfter = 0; lock.unlock() }
}
