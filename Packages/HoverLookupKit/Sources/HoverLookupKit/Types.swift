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
    case secureInput, excludedTarget, accessibilityUnavailable, accessibilityPermission
    case accessibilityHitTestFailed, securityInspectionFailed, securityDepthExceeded
    case accessibilityCallFailed(operation: HoverDiagnostic.AccessibilityOperation, code: Int32)
    case screenPermission, captureFailed, recognitionFailed, noText, tooLong
    case timedOut, requestBusy, fallbackTargetUnavailable
    case ocrFailure(OCRFailure)
}

public protocol HoverTextReading {
    func word(at point: CGPoint, primaryTop: CGFloat) async throws -> HoverWordHit?
}

public protocol ScreenImageCapturing {
    func capture(_ region: ScreenRegion) async throws -> CGImage
}

public protocol HoverWordRecognizing {
    func prepare() throws
    func recognizeWord(_ image: CGImage, region: CGRect, point: CGPoint) async throws -> HoverWordHit?
}

public extension HoverWordRecognizing {
    func prepare() throws {}
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
    public enum Outcome: String, Sendable { case started, hit, miss, failed, cancelled, blocked, timedOut, fallback }
    public enum Reason: String, Sendable { case modifier, interaction, ownWindow, hostBusy, permission, secureInput, safetyCheck, hitTestFailed, securityInspection, securityDepth, providerBusy, unsupportedInterface, fallbackTarget, ocrModelResources, ocrEngine }
    public enum AccessibilityOperation: String, Sendable {
        case elementAtPosition, missingElement, elementProcessID, invalidProcessID
    }
    public enum TargetRejection: String, Sendable {
        case foregroundMissing, ownProcess, windowListUnavailable, windowMetadata
        case otherProcess, desktopWindow, systemWindow, noWindowAtPoint, windowLimit
    }
    public let targetRejection: TargetRejection?
    public let foregroundPID: Int32?
    public let windowPID: Int32?
    public let windowLayer: Int?
    public let accessibilityOperation: AccessibilityOperation?
    public let systemCode: Int32?
    public let reason: Reason?
    public let stage: Stage
    public let outcome: Outcome
    public let milliseconds: Int
    public let imageWidth: Int
    public let imageHeight: Int
    public let imageBytesPerRow: Int
    // Deliberately no text, image, window title, app name, or arbitrary error description.
    init(_ stage: Stage, _ outcome: Outcome, since start: TimeInterval, reason: Reason? = nil,
         accessibilityOperation: AccessibilityOperation? = nil, systemCode: Int32? = nil,
         targetRejection: TargetRejection? = nil, foregroundPID: Int32? = nil,
         windowPID: Int32? = nil, windowLayer: Int? = nil,
         imageWidth: Int = 0, imageHeight: Int = 0, imageBytesPerRow: Int = 0) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.imageBytesPerRow = imageBytesPerRow
        self.targetRejection = targetRejection
        self.foregroundPID = foregroundPID
        self.windowPID = windowPID
        self.windowLayer = windowLayer
        self.accessibilityOperation = accessibilityOperation
        self.systemCode = systemCode
        self.reason = reason
        self.stage = stage; self.outcome = outcome
        milliseconds = Int(max(0, ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
}

func quartzRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
}
