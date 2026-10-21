import AppKit
import ScreenCaptureKit

public struct ScreenImageService: ScreenImageCapturing {
    public init() {}
    public func capture(_ region: ScreenRegion) async throws -> CGImage { try await Self.capture(region) }
    public static func capture(_ region: ScreenRegion) async throws -> CGImage {
        try Task.checkCancellation()
        guard region.rect.width.isFinite, region.rect.height.isFinite,
              region.rect.width > 0, region.rect.height > 0,
              region.scale.isFinite, region.scale > 0,
              region.screenFrame.contains(region.rect) else { throw HoverLookupError.captureFailed }
        if #available(macOS 14.0, *) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
                throw HoverLookupError.captureFailed
            }
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(x: region.rect.minX - region.screenFrame.minX,
                y: region.screenFrame.maxY - region.rect.maxY, width: region.rect.width, height: region.rect.height)
            // Keep large accidental selections bounded to at most 4096 pixels on either edge.
            let scale = min(region.scale, 4096 / max(region.rect.width, region.rect.height))
            configuration.width = max(1, Int(ceil(region.rect.width * scale)))
            configuration.height = max(1, Int(ceil(region.rect.height * scale)))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()
            return image
        } else {
            // Modern capture explicitly excludes our windows. The old API needs
            // a compositor turn after the overlay is removed.
            try await Task.sleep(nanoseconds: 100_000_000)
            return try legacyCapture(region)
        }
    }

    @available(macOS, introduced: 12.0, obsoleted: 14.0)
    private static func legacyCapture(_ region: ScreenRegion) throws -> CGImage {
        let rect = quartzRect(region.rect, primaryTop: region.primaryTop)
        let nativePixels = region.rect.width * region.rect.height * region.scale * region.scale
        let option: CGWindowImageOption = nativePixels <= 16_777_216 ? .bestResolution : .nominalResolution
        guard region.rect.width * region.rect.height <= 16_777_216,
              let image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, option) else {
            throw HoverLookupError.captureFailed
        }
        // CoreGraphics allocates the selected region only, never a full-desktop cache.
        let longest = max(image.width, image.height)
        guard longest > 4096 else { return image }
        let scale = 4096.0 / Double(longest)
        guard let context = CGContext(data: nil, width: max(1, Int(Double(image.width) * scale)),
            height: max(1, Int(Double(image.height) * scale)), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw HoverLookupError.captureFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(context.width), height: CGFloat(context.height)))
        guard let resized = context.makeImage() else { throw HoverLookupError.captureFailed }
        return resized
    }
}

