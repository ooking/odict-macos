import Foundation

@main private struct MacDeviceIdentifierChecks {
    static func main() {
        // Fixed synthetic UUID and independently calculated cross-language contract vector.
        let uuid = "123e4567-e89b-12d3-a456-426614174000"
        let expected = "f61e8236faaa55079c3545fefc881f8ad3c20085320db48d913af04756c7bf64"
        precondition(MacDeviceIdentifier.derive(from: uuid) == expected)
        precondition(MacDeviceIdentifier.derive(from: uuid.uppercased()) == expected)
        precondition(MacDeviceIdentifier.derive(from: "123e4567-e89b-12d3-a456-426614174001") != expected)
        for invalid in ["", "not-a-uuid", "00000000-0000-0000-0000-000000000000"] {
            precondition(MacDeviceIdentifier.derive(from: invalid) == nil)
        }
        print("Mac device identifier contract checks passed (synthetic input only).")
    }
}
