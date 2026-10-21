import Foundation

private actor SettingsFixtureClient: AIQueryServing {
    private var pending: CheckedContinuation<AIAnswer, Error>?
    var isPending: Bool { pending != nil }
    func answer(text: String, kind: AITaskKind, target: AITargetLanguage?, settings: AISavedSettings?) async throws -> AIAnswer {
        switch settings!.configuration.model {
        case "failure": throw AIError.http(401)
        case "timeout": throw URLError(.timedOut)
        case "delayed": return try await withCheckedThrowingContinuation { pending = $0 }
        default: return AIAnswer(kind: .translation, translation: "你好", explanation: "", examples: [])
        }
    }
    func finish() {
        pending?.resume(returning: AIAnswer(kind: .translation, translation: "迟到结果", explanation: "", examples: []))
        pending = nil
    }
}
@main private struct AISettingsChecks {
    @MainActor static func settle(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("settings state did not settle")
    }
    static func pending(_ client: SettingsFixtureClient) async throws {
        for _ in 0..<200 {
            if await client.isPending { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("fixture request did not start")
    }
    @MainActor static func main() async throws {
        var configuration = AIConfiguration()
        configuration.address = "https://fixture.invalid/v1"
        configuration.model = "success"
        let saved = AISavedSettings(configuration: configuration, key: "")
        let client = SettingsFixtureClient()
        let model = AISettingsModel(client: client, loadSettings: { saved }, saveSettings: { _, _ in })
        model.load()
        try await settle { model.loaded }
        model.verify()
        precondition(model.verificationState == .checking)
        try await settle { !model.isVerifying }
        precondition(model.verificationState == .success && model.message == nil)
        // A redraw or repeated load cannot erase the visible verification result.
        model.load()
        precondition(model.verificationState == .success)
        model.update(\.model, value: "failure")
        precondition(model.verificationState == .idle)
        model.verify()
        try await settle { !model.isVerifying }
        guard case .failure(let authError) = model.verificationState else { preconditionFailure("missing failure feedback") }
        precondition(authError.contains("密钥"))
        model.update(\.model, value: "timeout")
        model.verify()
        try await settle { !model.isVerifying }
        guard case .failure(let timeout) = model.verificationState else { preconditionFailure("missing timeout feedback") }
        precondition(timeout.contains("超时"))
        model.update(\.model, value: "delayed")
        model.verify()
        try await pending(client)
        model.cancelVerification()
        precondition(model.verificationState == .cancelled && !model.isVerifying)
        await client.finish()
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(model.verificationState == .cancelled)
        model.verify()
        try await pending(client)
        model.update(\.address, value: "https://changed.invalid/v1")
        await client.finish()
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(model.verificationState == .idle && !model.isVerifying)
        model.update(\.address, value: "")
        model.verify()
        guard case .failure = model.verificationState else { preconditionFailure("missing configuration feedback") }
        model.update(\.address, value: saved.configuration.address)
        model.update(\.model, value: "success")
        model.verify()
        try await settle { !model.isVerifying }
        precondition(model.verificationState == .success)
        model.save()
        try await settle { !model.isSaving }
        precondition(model.succeeded && model.message?.contains("保存") == true && model.verificationState == .idle)
        model.close()
        precondition(model.key.isEmpty && !model.loaded && !model.isVerifying)
        print("PASS: visible verification states; independent save feedback; auth/timeout/config errors; cancellation; edits; stale response rejection; close cleanup. No real network, Keychain, or saved preferences modified.")
    }
}
