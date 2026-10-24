import AppKit
import os

#if DEBUG
import Darwin

/// Event-driven, main-process measurements only. No timers, images, query text,
/// heap walks or retained samples. Each span has an independent correlation ID.
enum MemoryPhaseDiagnostics {
    private static let log = Logger(subsystem: "com.touchany.odict.mac", category: "MemoryPhases")

    struct Span: Sendable {
        private let scope: String
        private let id = UUID().uuidString
        private let start = ProcessInfo.processInfo.systemUptime

        init(_ scope: String) {
            self.scope = scope
            mark("begin")
        }

        func mark(_ event: String, width: Int = 0, height: Int = 0, bytesPerRow: Int = 0) {
            MemoryPhaseDiagnostics.record(scope: scope, event: event, id: id, start: start,
                                          width: width, height: height, bytesPerRow: bytesPerRow)
        }
    }

    static func snapshot(_ event: String, pendingRequests: Int = 0, payloadBytes: Int = 0,
                         width: Int = 0, height: Int = 0, bytesPerRow: Int = 0) {
        record(scope: "lifecycle", event: event, id: "-", start: ProcessInfo.processInfo.systemUptime,
               width: width, height: height, bytesPerRow: bytesPerRow,
               pendingRequests: pendingRequests, payloadBytes: payloadBytes)
    }

    private static func record(scope: String, event: String, id: String, start: TimeInterval,
                               width: Int = 0, height: Int = 0, bytesPerRow: Int = 0,
                               pendingRequests: Int = 0, payloadBytes: Int = 0) {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        // A lifetime peak is not a per-stage maximum. A rise between adjacent
        // checkpoints locates new peaks; an unchanged value proves no such thing.
        log.notice("scope=\(scope, privacy: .public) event=\(event, privacy: .public) span=\(id, privacy: .public) uptime=\(uptime) elapsedMs=\((uptime - start) * 1000) status=\(status) footprintBytes=\(usage.ri_phys_footprint) lifetimePeakBytes=\(usage.ri_lifetime_max_phys_footprint) residentBytes=\(usage.ri_resident_size) width=\(width) height=\(height) bytesPerRow=\(bytesPerRow) pendingRequests=\(pendingRequests) payloadBytes=\(payloadBytes)")
    }
}
#endif

@MainActor
enum LifecycleDiagnostics {
    private static let log = Logger(subsystem: "com.touchany.odict.mac", category: "WindowLifecycle")
    private static let start = ProcessInfo.processInfo.systemUptime

    static func record(_ event: String, panel: NSWindow? = nil) {
        #if DEBUG
        MemoryPhaseDiagnostics.snapshot(event)
        #endif
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let visible = panel?.isVisible ?? false
        let key = panel?.isKeyWindow ?? false
        let onSpace = panel?.isOnActiveSpace ?? false
        log.debug("event=\(event, privacy: .public) elapsed=\(elapsed) visible=\(visible) key=\(key) onActiveSpace=\(onSpace) active=\(NSApp.isActive)")
    }

    static func statusClick() {
        let delay = NSApp.currentEvent.map { max(0, ProcessInfo.processInfo.systemUptime - $0.timestamp) } ?? 0
        log.debug("event=status.click dispatchDelay=\(delay)")
    }
}
