import Foundation
import Security

enum KeychainStore {
    private static let worker = BlockingWorkQueue(label: "com.touchany.odict.keychain")

    static func loadSettings() async throws -> SavedServiceSettings {
        try await worker.perform {
            let key = try readSynchronously()
            let address = UserDefaults.standard.string(forKey: "apiURL") ?? ServiceSettingsStore.defaultAddress
            return SavedServiceSettings(address: address, key: key)
        }
    }

    static func saveSettings(address: String, key: String) async throws {
        try await worker.perform {
            try saveSynchronously(key)
            // Commit the matching endpoint on the same queue, even if the UI closes.
            UserDefaults.standard.set(address, forKey: "apiURL")
        }
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
