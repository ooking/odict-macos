import Foundation

public enum HoverWords {
    private static let componentSeparators: Set<Character> = [".", "．", "/", "\\", "_", ":", "@"]

    /// Keep the original String ranges: repeated words must retain separate boxes.
    public static func ranges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        func append(_ range: Range<String.Index>) {
            guard !range.isEmpty else { return }
            if let previous = ranges.last {
                let separator = text[previous.upperBound..<range.lowerBound]
                if separator == "-" || separator == "'" || separator == "’" {
                    ranges[ranges.count - 1] = previous.lowerBound..<range.upperBound
                    return
                }
            }
            ranges.append(range)
        }
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .localized]) { _, range, _, _ in
            // Foundation may return dotted names/URLs as a single word. Split
            // components before AX/OCR hit testing, retaining exact source indices.
            var start = range.lowerBound
            for index in text[range].indices where componentSeparators.contains(text[index]) {
                append(start..<index)
                start = text.index(after: index)
            }
            append(start..<range.upperBound)
        }
        return ranges
    }

    public static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
    }

    public static func screenRect(_ box: CGRect, region: CGRect) -> CGRect {
        CGRect(x: region.minX + box.minX * region.width, y: region.minY + box.minY * region.height,
               width: box.width * region.width, height: box.height * region.height)
    }

    public static func region(around point: CGPoint, screen: CGRect) -> CGRect {
        CGRect(x: point.x - 320, y: point.y - 80, width: 640, height: 160).intersection(screen)
    }
}

