import AppKit
import CoreText
import Vision
import CoreML

@main
struct HoverWordChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "HoverWordChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func image(text value: String = "echo", fontName: String = "Menlo",
                      origins: [CGFloat] = [40, 300]) throws -> CGImage {
        guard let context = CGContext(data: nil, width: 640, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.unavailable
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 160))
        let font = CTFontCreateWithName(fontName as CFString, 32, nil)
        let text = NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        for x in origins {
            context.textPosition = CGPoint(x: x, y: 80)
            CTLineDraw(line, context)
        }
        guard let result = context.makeImage() else { throw CaptureError.unavailable }
        return result
    }

    static func main() async throws {
        // No capture, permissions, UI automation, preferences, keychain or network access.
        try require(OCRComputePolicy.preferred(systemMajorVersion: 27) == .compatibleCPU, "Affected OS must bypass the E5 model")
        for version in [12, 13, 14, 26, 28] {
            try require(OCRComputePolicy.preferred(systemMajorVersion: version) == .automatic, "Workaround escaped the affected OS generation")
        }
        if #available(macOS 14.0, *) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try OCRComputePolicy.compatibleCPU.configure(request)
            try require(request.revision == OCRComputePolicy.compatibilityRevision, "Compatibility path used the broken model revision")
            let stages = try request.supportedComputeStageDevices
            try require(!stages.isEmpty, "CPU test did not inspect a compute stage")
            for stage in stages.keys {
                guard case .cpu = request.computeDevice(for: stage) else {
                    throw CaptureError.recognitionFailed
                }
            }
        }
        let fixtures: [(HoverTrigger, NSEvent.ModifierFlags)] = [
            (.command, .command), (.control, .control), (.option, .option), (.shift, .shift), (.none, []),
        ]
        for (trigger, flags) in fixtures {
            try require(trigger.matches(flags.union(.capsLock)), "Caps Lock changed the hover gesture")
            for other in [NSEvent.ModifierFlags.command, .control, .option, .shift] where other != flags {
                try require(!trigger.matches(flags.union(other)), "A keyboard chord incorrectly armed hover lookup")
            }
        }
        try require(HoverTrigger.control.isHeld(in: [.control, .shift]), "A chord incorrectly released the Control gesture")
        try require(!HoverTrigger.control.matches([]), "Default Control gesture became unconditional")
        let text = "echo echo state-of-the-art don't café"
        let ranges = HoverWords.ranges(in: text)
        let tokens = ranges.map { String(text[$0]) }
        try require(tokens == ["echo", "echo", "state-of-the-art", "don't", "café"], "Word boundaries lost connectors or accents")
        try require(ranges[0] != ranges[1], "Repeated words reused the first range")
        try require(HoverWords.ranges(in: "  , . !  ").isEmpty, "Punctuation became a word")
        let dotted = "TextRecognition.frame"
        let dottedRanges = HoverWords.ranges(in: dotted)
        try require(dottedRanges.map { String(dotted[$0]) } == ["TextRecognition", "frame"],
                    "Dotted names must not be one dictionary word")
        let frameOffset = (dotted as NSString).range(of: "frame").location
        try require(dottedRanges.first { NSLocationInRange(frameOffset, NSRange($0, in: dotted)) }.map { String(dotted[$0]) } == "frame",
                    "AX character offset selected the entire dotted name")
        let dotOffset = (dotted as NSString).range(of: ".").location
        try require(!dottedRanges.contains { NSLocationInRange(dotOffset, NSRange($0, in: dotted)) }, "AX punctuation became a word")
        let path = "https://example.com/TextRecognition.frame foo_bar state-of-the-art don't"
        try require(HoverWords.ranges(in: path).map { String(path[$0]) } ==
                    ["https", "example", "com", "TextRecognition", "frame", "foo", "bar", "state-of-the-art", "don't"],
                    "Path boundaries or dictionary connectors regressed")
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
        let start = ProcessInfo.processInfo.systemUptime
        let fullText = try await recognizer.recognize(fixture)
        try require(fullText.lowercased() == "echo echo", "Screenshot OCR regression")
        let chinese = try await recognizer.recognize(image(text: "中文", fontName: "PingFangSC-Regular"))
        try require(chinese.replacingOccurrences(of: " ", with: "") == "中文中文", "Chinese screenshot OCR regression")
        let mixed = try await recognizer.recognize(image(text: "echo 中文", fontName: "PingFangSC-Regular"))
        try require(mixed.replacingOccurrences(of: " ", with: "") == "echo中文echo中文", "Mixed-language screenshot OCR regression")
        let region = CGRect(x: -1280, y: 100, width: 640, height: 160)
        let second = try await recognizer.recognizeWord(fixture, region: region, point: CGPoint(x: -942, y: 191))
        try require(second?.text.lowercased() == "echo", "OCR did not recognize the second word")
        try require((second?.anchor.minX ?? -2000) > -1000, "Repeated OCR word returned the first word's box")
        let first = try await recognizer.recognizeWord(fixture, region: region, point: CGPoint(x: -1202, y: 191))
        try require(first?.text.lowercased() == "echo" && (first?.anchor.maxX ?? 0) < -1100, "First OCR word box is incorrect")
        let blank = try await recognizer.recognizeWord(fixture, region: region, point: CGPoint(x: -1050, y: 191))
        try require(blank == nil, "Whitespace incorrectly selected a nearby word")
        let dottedImage = try image(text: dotted, origins: [40])
        let font = CTFontCreateWithName("Menlo" as CFString, 32, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: dotted,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        func glyphPoint(at index: Int) -> CGPoint {
            let left = CTLineGetOffsetForStringIndex(line, index, nil)
            let right = CTLineGetOffsetForStringIndex(line, index + 1, nil)
            return CGPoint(x: region.minX + 40 + (left + right) / 2, y: region.minY + 91)
        }
        let frameHit = try await recognizer.recognizeWord(dottedImage, region: region, point: glyphPoint(at: frameOffset + 2))
        try require(frameHit?.text.lowercased() == "frame", "OCR selected a dotted name instead of the hovered suffix")
        let nameHit = try await recognizer.recognizeWord(dottedImage, region: region, point: glyphPoint(at: 4))
        try require(nameHit?.text.lowercased() == "textrecognition", "OCR selected the wrong side of a dot")
        let dotHit = try await recognizer.recognizeWord(dottedImage, region: region, point: glyphPoint(at: dotOffset))
        try require(dotHit == nil, "OCR punctuation selected an adjacent word")
        let cancelled = Task { try await recognizer.recognizeWord(fixture, region: region, point: CGPoint(x: -942, y: 191)) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw NSError(domain: "HoverWordChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cancelled OCR returned a result"])
        } catch is CancellationError { }
        print("Hover word checks passed (OS compute policy, CPU stages, screenshot OCR, boundaries, coordinates, synthetic OCR, whitespace and cancellation). OCR elapsed: \(ProcessInfo.processInfo.systemUptime - start) seconds")
    }
}
