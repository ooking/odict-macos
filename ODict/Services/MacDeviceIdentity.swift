import Foundation
import CryptoKit
import IOKit

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
// The device identifier is the hardware UUID with an odict prefix; never log it.
enum MacDeviceIdentity {
    static func deviceID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              let uuid = UUID(uuidString: value), uuid != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else { return nil }
        return "odict" + uuid.uuidString.lowercased()
    }
}
actor MacDeviceService {
    static let shared = MacDeviceService()
    private struct Material: Codable { var keyID: String; var privateKey: Data; var sequence: Int64; var registeredEndpoint: String?; var registeredDeviceID: String? }
    private var material: Material?
    private var registration: Task<Void, Error>?
    private var signedTail: Task<Void, Never>?
    private var registeringEndpoint: String?
    private let storage = "macos-device-signing-v1"
    private func load() async throws -> Material {
        if let material { return material }
        let value = try await KeychainStore.loadSecret(account: storage)
        // Recheck after awaiting the shared Keychain worker.
        if let material { return material }
        let result: Material
        if let data = value.data(using: .utf8), !value.isEmpty {
            result = try JSONDecoder().decode(Material.self, from: data)
        } else {
            result = Material(keyID: UUID().uuidString.lowercased(), privateKey: Curve25519.Signing.PrivateKey().rawRepresentation, sequence: 0)
            material = result
            do { try await persist(result) } catch { material = nil; throw error }
        }
        material = result
        return result
    }
    private func persist(_ value: Material) async throws {
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try await KeychainStore.saveSecret(text, account: storage)
    }
    func prepare(endpoint: String) async throws {
        guard let device = MacDeviceIdentity.deviceID() else { return }
        let current = try await load()
        if current.registeredEndpoint == endpoint, current.registeredDeviceID == device { return }
        if let registration, registeringEndpoint == endpoint { return try await registration.value }
        let task = Task { try await self.register(endpoint: endpoint, device: device, value: current) }
        registration = task; registeringEndpoint = endpoint
        defer { registration = nil; registeringEndpoint = nil }
        try await task.value
    }
    private func register(endpoint: String, device: String, value: Material) async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: value.privateKey)
        struct Challenge: Decodable, Sendable { let challenge: String }
        let challenge = try await AccountTransport.post(Challenge.self, endpoint: endpoint, path: "/installations/challenge", body: AccountTransport.body(["device_id": device, "public_key": key.publicKey.rawRepresentation.base64URL]))
        let message = "odict-register-v1\n" + value.keyID + "\n" + challenge.challenge
        _ = try await AccountTransport.post(AccountAcknowledgement.self, endpoint: endpoint, path: "/installations/register", body: AccountTransport.body(["key_id": value.keyID, "challenge": challenge.challenge, "signature": try key.signature(for: Data(message.utf8)).base64URL]))
        var updated = material ?? value; updated.registeredEndpoint = endpoint; updated.registeredDeviceID = device
        try await persist(updated); material = updated
    }
    func headers(endpoint: String, path: String, body: Data) async throws -> [String: String] {
        guard let device = MacDeviceIdentity.deviceID() else { return [:] }
        try await prepare(endpoint: endpoint)
        var value = try await load()
        guard value.sequence < Int64.max else { throw DictionaryError.configuration }
        value.sequence += 1
        // Reserve before awaiting persistence so actor reentrancy cannot reuse a sequence.
        material = value
        try await persist(value)
        let timestamp = String(Int64(Date().timeIntervalSince1970)); let sequence = String(value.sequence)
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let message = ["odict-device-v1", "POST", path, device, value.keyID, timestamp, sequence, hash].joined(separator: "\n")
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: value.privateKey)
        return ["X-ODict-Key-ID": value.keyID, "X-ODict-Device-ID": device, "X-ODict-Timestamp": timestamp, "X-ODict-Sequence": sequence,
                "X-ODict-Signature": try key.signature(for: Data(message.utf8)).base64URL]
    }
    func signedPost<T: Decodable & Sendable>(_ type: T.Type, endpoint: String, path: String, body: Data) async throws -> T {
        let previous = signedTail
        let request = Task<T, Error> {
            if let previous { await previous.value }
            try Task.checkCancellation()
            let headers = try await self.headers(endpoint: endpoint, path: path, body: body)
            try Task.checkCancellation()
            return try await AccountTransport.post(type, endpoint: endpoint, path: path, body: body, deviceHeaders: headers)
        }
        signedTail = Task { _ = await request.result }
        return try await withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })
    }
    func invalidateRegistration() async throws {
        var value = try await load(); value.registeredEndpoint = nil; material = value; try await persist(value)
    }
    func report(endpoint: String) async throws {
        guard MacDeviceIdentity.deviceID() != nil else { return }
        let system = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let info = Bundle.main.infoDictionary ?? [:]
        let body = try AccountTransport.body(["app_version": info["CFBundleShortVersionString"] as? String ?? "0", "app_build": info["CFBundleVersion"] as? String ?? "0",
                                              "os_major": system.majorVersion, "os_minor": system.minorVersion, "process_arch": architecture, "notice_version": 1])
        _ = try await signedPost(AccountAcknowledgement.self, endpoint: endpoint, path: "/installations/report", body: body)
    }
}
