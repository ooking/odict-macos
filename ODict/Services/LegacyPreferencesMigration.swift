import Foundation

enum LegacyPreferencesMigration {
    static func run(defaults: UserDefaults = .standard) {
        let marker = "didMigrateUnsandboxedPreferencesV1"
        guard !defaults.bool(forKey: marker), let bundleID = Bundle.main.bundleIdentifier else { return }
        // NSHomeDirectoryForUser resolves the real home, even when launched from a legacy container.
        guard let home = NSHomeDirectoryForUser(NSUserName()) else { return }
        let url = URL(fileURLWithPath: home).appendingPathComponent("Library/Containers")
            .appendingPathComponent(bundleID).appendingPathComponent("Data/Library/Preferences")
            .appendingPathComponent("\(bundleID).plist")
        guard FileManager.default.fileExists(atPath: url.path) else {
            defaults.set(true, forKey: marker)
            return
        }
        // Leave the marker unset on a read failure so a later launch can retry.
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= 256 * 1024,
              let data = try? Data(contentsOf: url),
              let legacy = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return }
        copyMissing(from: legacy, to: defaults)
        defaults.set(true, forKey: marker)
    }

    static func copyMissing(from legacy: [String: Any], to defaults: UserDefaults) {
        if defaults.object(forKey: "didWelcome") == nil, let value = legacy["didWelcome"] as? Bool { defaults.set(value, forKey: "didWelcome") }
        if defaults.object(forKey: "recentWords") == nil, let value = legacy["recentWords"] as? [String] {
            defaults.set(Array(value.lazy.filter { !$0.isEmpty && $0.count <= 255 }.prefix(20)), forKey: "recentWords")
        }
        // Storage format of the pinned KeyboardShortcuts 3.1.0; false means explicitly cleared.
        let key = "KeyboardShortcuts_toggleDictionary"
        if defaults.object(forKey: key) == nil, let value = legacy[key], value is String || value is Bool {
            defaults.set(value, forKey: key)
        }
    }
}
