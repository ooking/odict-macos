import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var category = SettingsCategory.general
    let ai = AISettingsModel()
    var didSave: (() -> Void)?

    func close() {
        ai.close()
    }
}
