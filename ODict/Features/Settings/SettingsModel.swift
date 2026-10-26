import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var showAI = false
    let ai = AISettingsModel()
    var didSave: (() -> Void)?

    func close() {
        ai.close()
    }
}
