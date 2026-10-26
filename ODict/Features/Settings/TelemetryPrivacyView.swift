import SwiftUI

struct TelemetryPrivacyView: View {
    @AppStorage("usageTelemetryEnabled") private var enabled = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("基础使用统计").font(AppTypography.section)
            Toggle("发送基础使用统计", isOn: $enabled).onChange(of: enabled) { TelemetryRuntime.setEnabled($0) }
            Text("启动时发送设备标识及应用与系统版本等基础信息，用于统计设备数量和活跃情况，关闭不影响使用。").font(AppTypography.secondary)
        }.foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
enum TelemetryRuntime {
    private static var task: Task<Void, Never>?
    private static var generation = UUID()
    static var enabled: Bool { (UserDefaults.standard.object(forKey: "usageTelemetryEnabled") as? Bool) ?? true }
    static func start() {
        guard enabled else { return }
        schedule()
    }
    static func setEnabled(_ value: Bool) { generation = UUID(); task?.cancel(); task = nil; if value { schedule() } }
    private static func schedule() {
        task?.cancel(); generation = UUID(); let run = generation
        task = Task {
            defer { if generation == run { task = nil } }
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                guard enabled else { return }
                do { try await MacDeviceService.shared.report(endpoint: ODictService.apiAddress) }
                catch {
                    try Task.checkCancellation(); try await Task.sleep(nanoseconds: 30_000_000_000)
                    guard enabled else { return }
                    if let failure = error as? AccountHTTPError, failure.status == 401 { try await MacDeviceService.shared.invalidateRegistration() }
                    try await MacDeviceService.shared.report(endpoint: ODictService.apiAddress)
                }
            } catch { /* Best effort. Never log identifiers, payloads or credentials. */ }
        }
    }
    static func stop() { generation = UUID(); task?.cancel(); task = nil }
}
