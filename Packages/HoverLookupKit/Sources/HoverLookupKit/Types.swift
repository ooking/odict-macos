import AppKit

public struct HoverWordHit: Sendable {
    public let text: String
    /// Global AppKit coordinates, in points, with the origin at the bottom left.
    public let anchor: CGRect
    public init(text: String, anchor: CGRect) { self.text = text; self.anchor = anchor }
}

public struct ScreenRegion: Sendable {
    public let rect: CGRect
    public let displayID: CGDirectDisplayID
    public let screenFrame: CGRect
    public let scale: CGFloat
    public let primaryTop: CGFloat
    public init(rect: CGRect, displayID: CGDirectDisplayID, screenFrame: CGRect, scale: CGFloat, primaryTop: CGFloat) {
        self.rect = rect; self.displayID = displayID; self.screenFrame = screenFrame
        self.scale = scale; self.primaryTop = primaryTop
    }
}

public enum HoverLookupError: Error {
    case secureInput, excludedTarget, accessibilityUnavailable
    case accessibilityHitTestFailed, securityInspectionFailed, securityDepthExceeded
    case screenPermission, captureFailed, recognitionFailed, noText, tooLong
    case timedOut, requestBusy
}

public protocol HoverTextReading {
    func word(at point: CGPoint, primaryTop: CGFloat) async throws -> HoverWordHit?
}

public protocol ScreenImageCapturing {
    func capture(_ region: ScreenRegion) async throws -> CGImage
}

public protocol HoverWordRecognizing {
    func recognizeWord(_ image: CGImage, region: CGRect, point: CGPoint) async throws -> HoverWordHit?
}

public enum HoverModifier: String, Sendable {
    case none, command, control, option, shift
    private var flags: NSEvent.ModifierFlags {
        switch self {
        case .none: return []
        case .command: return .command
        case .control: return .control
        case .option: return .option
        case .shift: return .shift
        }
    }
    public func matches(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.control, .option, .command, .shift]) == flags
    }
    public func isHeld(in modifiers: NSEvent.ModifierFlags) -> Bool {
        self == .none ? matches(modifiers) : modifiers.contains(flags)
    }
}

/// Small pointer movement may continue extraction; a result must still contain
/// the current pointer. Larger movement cancels and starts a fresh dwell.
public struct HoverStability: Sendable {
    public var dwellTolerance: CGFloat = 3
    public var extractionTolerance: CGFloat = 12
    public init() {}
    public func accepts(origin: CGPoint, current: CGPoint, extracting: Bool) -> Bool {
        hypot(current.x - origin.x, current.y - origin.y) <= (extracting ? extractionTolerance : dwellTolerance)
    }
    public func accepts(_ hit: HoverWordHit, at point: CGPoint) -> Bool {
        HoverWords.valid(hit.anchor) && hit.anchor.insetBy(dx: -1, dy: -2).contains(point)
    }
}

public struct HoverDiagnostic: Sendable {
    public enum Stage: String, Sendable { case accessibility, capture, recognition, request }
    public enum Outcome: String, Sendable { case started, hit, miss, failed, cancelled, blocked, timedOut }
    public enum Reason: String, Sendable { case modifier, interaction, ownWindow, hostBusy, permission, secureInput, safetyCheck, hitTestFailed, securityInspection, securityDepth, providerBusy }
    public let reason: Reason?
    public let stage: Stage
    public let outcome: Outcome
    public let milliseconds: Int
    // Deliberately no text, image, window title, app name, or arbitrary error description.
    init(_ stage: Stage, _ outcome: Outcome, since start: TimeInterval, reason: Reason? = nil) {
        self.reason = reason
        self.stage = stage; self.outcome = outcome
        milliseconds = Int(max(0, ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
}

func quartzRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
}
