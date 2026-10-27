import CryptoKit
import Foundation

/// Pure implementation of the shared v1 device-ID contract; no hardware or storage access.
enum MacDeviceIdentifier {
    static func derive(from hardwareUUID: String) -> String? {
        guard let uuid = UUID(uuidString: hardwareUUID),
              uuid != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else { return nil }
        let input = "odict:macos:device:v1:" + uuid.uuidString.lowercased()
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
