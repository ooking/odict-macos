import Foundation
import Security

enum KeychainStore {
    private static let worker = BlockingWorkQueue(label: "com.touchany.odict.keychain")

    static func loadSecret(account: String) async throws -> String {
        try await worker.perform { try readSynchronously(account: account) }
    }
    static func saveSecret(_ value: String, account: String) async throws {
        try await worker.perform { try saveSynchronously(value, account: account) }
    }

    static func loadAISettings() async throws -> AISavedSettings {
        try await worker.perform {
            // Read the endpoint/model and matching credential on the same serial queue as saves.
            AISavedSettings(configuration: AISettingsStore.configuration,
                            key: try readSynchronously(account: "ai-service-key"))
        }
    }

    static func saveAIKey(_ key: String, configuration: Data, preferenceKey: String) async throws {
        try await worker.perform {
            try saveSynchronously(key, account: "ai-service-key")
            UserDefaults.standard.set(configuration, forKey: preferenceKey)
            // Publish committed changes even if the caller closed its window during Keychain work.
            DispatchQueue.main.async { NotificationCenter.default.post(name: AISettingsStore.changed, object: nil) }
        }
    }

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.touchany.odict.mac",
         kSecAttrAccount as String: account]
    }

    private static func readSynchronously(account: String) throws -> String {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw StorageError(status: status) }
        return value
    }

    private static func saveSynchronously(_ key: String, account: String) throws {
        let query = query(account: account)
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
