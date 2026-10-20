import Foundation
import Security

enum KeychainStore {
    // Security.framework calls are synchronous and can wait for system authorization.
    // Serialize them off the UI thread; never cache the returned secret.
    private static let queue = DispatchQueue(label: "com.touchany.odict.keychain", qos: .userInitiated)

    static func read() async throws -> String {
        try await perform { try readSynchronously() }
    }

    static func save(_ key: String) async throws {
        try await perform { try saveSynchronously(key) }
    }

    private static func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let cancellation = KeychainCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let value: Value = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try cancellation.check()
                        let value = try operation()
                        try cancellation.check()
                        return value
                    })
                }
            }
            try Task.checkCancellation()
            return value
        }, onCancel: { cancellation.cancel() })
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.touchany.odict.mac",
         kSecAttrAccount as String: "dictionary-read-key"]
    }

    private static func readSynchronously() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw StorageError(status: status) }
        return value
    }

    private static func saveSynchronously(_ key: String) throws {
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError(status: status) }
            return
        }
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(values) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw StorageError(status: added) }
        } else if status != errSecSuccess { throw StorageError(status: status) }
    }

    struct StorageError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "无法访问钥匙串（\(status)），请解锁钥匙串后重试。" }
    }
}

// A running Security call cannot be interrupted. Skip cancelled queued work and
// discard its result if cancellation arrives while waiting for the system.
private final class KeychainCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}
