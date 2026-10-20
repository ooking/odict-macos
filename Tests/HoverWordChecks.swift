import AppKit
import CoreText

@main
struct HoverWordChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "HoverWordChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func image() throws -> CGImage {
        guard let context = CGContext(data: nil, width: 640, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.unavailable
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 160))
        let font = CTFontCreateWithName("Menlo" as CFString, 32, nil)
        let text = NSAttributedString(string: "echo", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        for x in [CGFloat(40), CGFloat(300)] {
            context.textPosition = CGPoint(x: x, y: 80)
            CTLineDraw(line, context)
        }
        guard let result = context.makeImage() else { throw CaptureError.unavailable }
        return result
    }

    static func main() async throws {
        // No capture, permissions, UI automation, preferences, keychain or network access.
        let text = "echo echo state-of-the-art don't café"
        let ranges = HoverWords.ranges(in: text)
        let tokens = ranges.map { String(text[$0]) }
        try require(tokens == ["echo", "echo", "state-of-the-art", "don't", "café"], "Word boundaries lost connectors or accents")
        try require(ranges[0] != ranges[1], "Repeated words reused the first range")
        try require(HoverWords.ranges(in: "  , . !  ").isEmpty, "Punctuation became a word")
        let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let point = CGPoint(x: -1430, y: 690)
        let crop = HoverWords.region(around: point, screen: screen)
        try require(screen.contains(crop) && crop.contains(point), "Edge crop left the secondary display")
        let box = CGRect(x: 0.25, y: 0.5, width: 0.2, height: 0.1)
        let bounds = HoverWords.screenRect(box, region: CGRect(x: -1200, y: 100, width: 400, height: 200))
        try require(bounds == CGRect(x: -1100, y: 200, width: 80, height: 20), "Normalized OCR coordinates drifted")
        let source = CGRect(x: 700, y: 450, width: 80, height: 25)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cardSize = CGSize(width: 440, height: 440)
        let card = CGRect(origin: CaptureGeometry.hoverPanelOrigin(size: cardSize, anchor: source, visible: visible), size: cardSize)
        try require(visible.contains(card) && !card.intersects(source), "Clamped card covered the source word")
        let quartz = CaptureGeometry.quartzRect(bounds, primaryTop: 900)
        try require(CaptureGeometry.quartzRect(quartz, primaryTop: 900) == bounds, "AX coordinate conversion did not round trip")

        let recognizer = ScreenTextService()
        let fixture = try image()
        let region = CGRect(x: -1280, y: 100, width: 640, height: 160)
        let second = try await recognizer.recognizeWord(fixture, region: region, point: CGPoint(x: -942, y: 191))
        try require(second?.text.lowercased() == "echo", "OCR did not recognize the second word")
        try require((second?.anchor.minX ?? -2000) > -1000, "Repeated OCR word returned the first word's box")
        let first = try await recognizer.recognizeWord(fixture, region: region, point: CGPoint(x: -1202, y: 191))
        try require(first?.text.lowercased() == "echo" && (first?.anchor.maxX ?? 0) < -1100, "First OCR word box is incorrect")
        let blank = try await recognizer.recognizeWord(fixture, region: region, point: CGPoint(x: -1050, y: 191))
        try require(blank == nil, "Whitespace incorrectly selected a nearby word")
        let cancelled = Task { try await recognizer.recognizeWord(fixture, region: region, point: CGPoint(x: -942, y: 191)) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw NSError(domain: "HoverWordChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cancelled OCR returned a result"])
        } catch is CancellationError { }
        print("Hover word checks passed (boundaries, coordinates, synthetic OCR, whitespace and cancellation)")
    }
}
