import AppKit
import ApplicationServices
import Carbon

/// Only produced after validating the pointer's window and any available
/// focused-element security metadata. It is not a general AX-error fallback.
struct AccessibilityOCRFallback: Error {
    let operation: HoverDiagnostic.AccessibilityOperation
    let code: Int32
    let targetPID: pid_t
    var point: CGPoint = .zero
    var dockPID: pid_t? = nil
    var screenBounds: CGRect? = nil
}

struct FallbackTargetRejection: Error {
    let reason: HoverDiagnostic.TargetRejection
    let foregroundPID: Int32?
    var windowPID: Int32? = nil
    var windowLayer: Int? = nil
}

enum UnsupportedAccessibilityTarget {
    private static let windowWorker = BlockingWorkQueue(label: "HoverLookupKit.windowTarget")

    static func revalidate(_ target: AccessibilityOCRFallback) async throws {
        try await windowWorker.perform {
            guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                           kCGNullWindowID) as? [[String: Any]] else {
                throw FallbackTargetRejection(reason: .windowListUnavailable, foregroundPID: nil)
            }
            try checkPoint(target.point, pid: target.targetPID, windows: windows,
                dockPID: target.dockPID, screenBounds: target.screenBounds)
        }
    }

    static func validate(at point: CGPoint, frontmostPID: pid_t?,
                         context: AXReadContext, dockPID: pid_t? = nil,
                         screenBounds: CGRect? = nil) throws -> pid_t {
        guard !IsSecureEventInputEnabled() else { throw HoverLookupError.secureInput }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else {
            throw FallbackTargetRejection(reason: .windowListUnavailable, foregroundPID: frontmostPID)
        }
        // Hover targets the visible window under the pointer. Keyboard focus may
        // remain in an entirely different application.
        let pid = try targetPID(at: point, windows: windows, dockPID: dockPID,
            screenBounds: screenBounds, foregroundPID: frontmostPID)
        let app = AXUIElementCreateApplication(pid)
        let focused = try context.attribute(app, kAXFocusedUIElementAttribute)
        // An unsupported app may expose no focused element at all. System secure
        // input and pointer-window ownership remain mandatory in that case.
        // If metadata exists, inspect it; unknown errors continue to fail closed.
        if let focused {
            guard CFGetTypeID(focused) == AXUIElementGetTypeID() else {
                throw HoverLookupError.securityInspectionFailed
            }
            var next: AXUIElement? = (focused as! AXUIElement)
            var visited: [AXUIElement] = []
            for _ in 0..<64 {
                guard let element = next else { break }
                guard !visited.contains(where: { CFEqual($0, element) }) else {
                    throw HoverLookupError.securityDepthExceeded
                }
                visited.append(element)
                let role = try context.attribute(element, kAXRoleAttribute) as? String
                let subrole = try context.attribute(element, kAXSubroleAttribute) as? String
                guard role != "AXSecureTextField", subrole != "AXSecureTextField" else {
                    throw HoverLookupError.secureInput
                }
                if role == kAXWindowRole || role == kAXApplicationRole { next = nil; break }
                if let parent = try context.attribute(element, kAXParentAttribute) {
                    guard CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                        throw HoverLookupError.securityInspectionFailed
                    }
                    next = (parent as! AXUIElement)
                } else { next = nil }
            }
            guard next == nil else { throw HoverLookupError.securityDepthExceeded }
        }
        guard !IsSecureEventInputEnabled() else { throw HoverLookupError.secureInput }
        return pid
    }

    /// Validate a previously selected target without requiring keyboard focus.
    static func ownsPoint(_ point: CGPoint, pid: pid_t, windows: [[String: Any]],
                          dockPID: pid_t? = nil, screenBounds: CGRect? = nil) -> Bool {
        do {
            try checkPoint(point, pid: pid, windows: windows, dockPID: dockPID, screenBounds: screenBounds)
            return true
        } catch { return false }
    }

    static func checkPoint(_ point: CGPoint, pid: pid_t, windows: [[String: Any]],
                           dockPID: pid_t? = nil, screenBounds: CGRect? = nil) throws {
        let owner = try targetPID(at: point, windows: windows, dockPID: dockPID,
            screenBounds: screenBounds, foregroundPID: nil)
        guard owner == pid else {
            throw FallbackTargetRejection(reason: .otherProcess, foregroundPID: nil, windowPID: owner)
        }
    }

    /// WindowServer order is front to back. Never search through an ordinary
    /// occluding window to find an application we prefer underneath it.
    static func targetPID(at point: CGPoint, windows: [[String: Any]], dockPID: pid_t? = nil,
                          screenBounds: CGRect? = nil, foregroundPID: pid_t? = nil) throws -> pid_t {
        for window in windows.prefix(256) {
            guard let raw = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw), bounds.contains(point) else { continue }
            let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue
            guard let alpha = window[kCGWindowAlpha as String] as? NSNumber,
                  let owner, owner > 0, let layer else {
                throw FallbackTargetRejection(reason: .windowMetadata, foregroundPID: foregroundPID,
                    windowPID: owner, windowLayer: layer)
            }
            if alpha.doubleValue <= 0 { continue }
            // Dock's full-display backdrop has visual bounds but does not define
            // the app under the pointer. Its actual Dock strip remains excluded.
            if owner == dockPID,
               layer == Int(CGWindowLevelForKey(.dockWindow)),
               let screenBounds, !screenBounds.isEmpty,
               bounds.contains(screenBounds.insetBy(dx: 1, dy: 1)) { continue }
            guard owner != ProcessInfo.processInfo.processIdentifier else {
                throw FallbackTargetRejection(reason: .ownProcess, foregroundPID: foregroundPID,
                    windowPID: owner, windowLayer: layer)
            }
            guard owner != dockPID else {
                throw FallbackTargetRejection(reason: .systemWindow, foregroundPID: foregroundPID,
                    windowPID: owner, windowLayer: layer)
            }
            guard layer >= 0 else {
                throw FallbackTargetRejection(reason: .desktopWindow, foregroundPID: foregroundPID,
                    windowPID: owner, windowLayer: layer)
            }
            return owner
        }
        throw FallbackTargetRejection(reason: windows.count > 256 ? .windowLimit : .noWindowAtPoint,
            foregroundPID: foregroundPID)
    }
}
