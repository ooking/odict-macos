import Foundation
import CryptoKit

actor AccountStore {
    static let shared = AccountStore()
    private var sessions: [String: AccountSession] = [:]
    private var refreshes: [String: Task<AccountSession, Error>] = [:]
    private var generations: [String: UUID] = [:]
    private func storage(_ endpoint: String) -> String {
        "account-session-" + SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func load(endpoint: String) async throws -> AccountSession? {
        if let value = sessions[endpoint] { return value }
        let run = generation(endpoint: endpoint)
        let text = try await KeychainStore.loadSecret(account: storage(endpoint))
        guard generations[endpoint] == run else { throw CancellationError() }
        if let value = sessions[endpoint] { return value }
        guard !text.isEmpty else { return nil }
        let value = try JSONDecoder().decode(AccountSession.self, from: Data(text.utf8))
        sessions[endpoint] = value
        return value
    }
    func generation(endpoint: String) -> UUID {
        if let value = generations[endpoint] { return value }
        let value = UUID(); generations[endpoint] = value; return value
    }
    func user(endpoint: String) async throws -> AccountUser? { try await load(endpoint: endpoint)?.user }
    func save(_ value: AccountSession, endpoint: String) async throws {
        try await KeychainStore.saveSecret(String(decoding: JSONEncoder().encode(value), as: UTF8.self), account: storage(endpoint))
        sessions[endpoint] = value
        // Keep only the active server's credentials in memory. Others stay in Keychain.
        for key in sessions.keys where key != endpoint { sessions.removeValue(forKey: key) }
    }
    func access(endpoint: String, rejectedToken: String? = nil) async throws -> String {
        try Task.checkCancellation()
        guard let value = try await load(endpoint: endpoint) else { throw DictionaryError.missingKey }
        if value.expiry > Date().addingTimeInterval(30), rejectedToken == nil || rejectedToken != value.accessToken { return value.accessToken }
        if let pending = refreshes[endpoint] { return try await pending.value.accessToken }
        let generation = generations[endpoint] ?? UUID(); generations[endpoint] = generation
        let task = Task<AccountSession, Error> {
            let body = try AccountTransport.body(["client_id": "odict-macos", "refresh_token": value.refreshToken])
            let next = try await AccountTransport.post(AccountSession.self, endpoint: endpoint, path: "/auth/client/refresh", body: body)
            try Task.checkCancellation()
            guard self.generations[endpoint] == generation else { throw CancellationError() }
            try await self.save(next, endpoint: endpoint)
            return next
        }
        refreshes[endpoint] = task
        defer { refreshes[endpoint] = nil }
        do { return try await task.value.accessToken }
        catch {
            if let failure = error as? AccountHTTPError, failure.status == 401, generations[endpoint] == generation {
                sessions[endpoint] = nil; try? await KeychainStore.saveSecret("", account: storage(endpoint))
            }
            throw error
        }
    }
    func logout(endpoint: String) async throws {
        generations[endpoint] = UUID()
        let pending = refreshes.removeValue(forKey: endpoint); pending?.cancel()
        if let pending { _ = try? await pending.value }
        let value = try await load(endpoint: endpoint)
        // Retain local credentials if revocation fails so the user can retry.
        if let value {
            _ = try await AccountTransport.post(AccountAcknowledgement.self, endpoint: endpoint, path: "/auth/client/logout", body: AccountTransport.body(["client_id": "odict-macos", "refresh_token": value.refreshToken]))
        }
        try await KeychainStore.saveSecret("", account: storage(endpoint)); sessions[endpoint] = nil
    }
    func exchange(endpoint: String, code: String, verifier: String, redirectURI: String) async throws -> AccountUser {
        let body = try AccountTransport.body(["client_id": "odict-macos", "code": code, "code_verifier": verifier, "redirect_uri": redirectURI])
        let next: AccountSession
        if MacDeviceIdentity.deviceID() != nil {
            next = try await MacDeviceService.shared.signedPost(AccountSession.self, endpoint: endpoint, path: "/auth/client/token", body: body)
        } else {
            next = try await AccountTransport.post(AccountSession.self, endpoint: endpoint, path: "/auth/client/token", body: body)
        }
        try Task.checkCancellation()
        let pending = refreshes.removeValue(forKey: endpoint); pending?.cancel()
        if let pending { _ = try? await pending.value }
        try Task.checkCancellation(); generations[endpoint] = UUID(); try await save(next, endpoint: endpoint)
        return next.user
    }
}
