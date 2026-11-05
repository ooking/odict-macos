import Foundation

private actor SettingsFixtureClient: AIQueryServing {
    private var pending: CheckedContinuation<AIAnswer, Error>?
    var isPending: Bool { pending != nil }
    func answer(text: String, kind: AITaskKind, target: AITargetLanguage?, settings: AISavedSettings?) async throws -> AIAnswer {
        switch settings!.configuration.model {
        case "failure": throw AIError.http(401)
        case "timeout": throw URLError(.timedOut)
        case "delayed": return try await withCheckedThrowingContinuation { pending = $0 }
        default: return AIAnswer(markdown: "你好")
        }
    }
    func models(address: String, key: String) async throws -> [String] { ["model-a", "model-b"] }
    func finish() {
        pending?.resume(returning: AIAnswer(markdown: "迟到结果"))
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
        model.fetchModels()
        try await settle { !model.isFetchingModels }
        precondition(model.availableModels == ["model-a", "model-b"])
        let originalID = model.selectedID
        model.updateShared(\.target, value: .japanese)
        model.updateShared(\.translationPrompt, value: "公共翻译偏好")
        let commonPreferences = model.shared
        model.updateKey("fixture-original")
        model.addProfile()
        let addedID = model.selectedID
        precondition(addedID != originalID && model.key.isEmpty && model.configuration.address.isEmpty)
        precondition(model.activeID == originalID && model.shared == commonPreferences)
        model.useSelectedProfile()
        precondition(model.activeID == addedID && model.savedActiveID == originalID)
        model.updateKey("fixture-added")
        model.select(originalID)
        precondition(model.key == "fixture-original" && model.configuration.model == "success")
        precondition(model.activeID == addedID && model.shared == commonPreferences)
        model.select(addedID)
        precondition(model.key == "fixture-added")
        model.setDefaultProfile(originalID)
        precondition(model.activeID == originalID && model.selectedID == addedID)
        model.removeProfile(addedID)
        precondition(model.selectedID == originalID && model.key == "fixture-original")
        precondition(model.activeID == originalID && model.shared == commonPreferences)
        let profileCount = model.profiles.count
        model.beginAddingProfile()
        model.updateKey("cancelled-secret")
        model.cancelEditingProfile()
        precondition(model.profiles.count == profileCount && model.selectedID == originalID && model.key == "fixture-original")
        model.beginEditingProfile(originalID)
        model.rename("取消的修改")
        model.update(\.model, value: "cancelled-model")
        model.updateKey("cancelled-secret")
        model.cancelEditingProfile()
        precondition(model.configuration.model == "success" && model.key == "fixture-original")
        precondition(!model.profiles.contains(where: { $0.name == "取消的修改" }))
        // Old libraries inherit the previously active profile's output settings.
        var oldConfiguration = configuration
        oldConfiguration.target = .french
        oldConfiguration.translationPrompt = "旧提示语"
        let oldProfile = AIServiceProfile(id: UUID(), name: "旧配置", configuration: oldConfiguration)
        let otherProfile = AIServiceProfile(id: UUID(), name: "其他配置", configuration: configuration)
        let oldLibrary = AIServiceLibrary(profiles: [oldProfile, otherProfile], selectedID: oldProfile.id)
        var migrated = try JSONDecoder().decode(AIServiceLibrary.self, from: JSONEncoder().encode(oldLibrary))
        precondition(migrated.effectiveConfiguration.target == .french)
        migrated.shared = migrated.preferences
        migrated.selectedID = otherProfile.id
        precondition(migrated.effectiveConfiguration.target == .french && migrated.effectiveConfiguration.translationPrompt == "旧提示语")
        model.close()
        precondition(model.key.isEmpty && !model.loaded && !model.isVerifying)
        print("PASS: visible verification states; independent save feedback; auth/timeout/config errors; cancellation; edits; stale response rejection; close cleanup. No real network, Keychain, or saved preferences modified.")
    }
}
