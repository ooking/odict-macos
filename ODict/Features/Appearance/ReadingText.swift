import AppKit
import SwiftUI

/// Uses explicit script ranges for mixed-language text, retaining Markdown
/// links and emphasis. Only this content view observes reading preferences.
struct ReadingText: View {
    @ObservedObject private var appearance = ReadingAppearanceStore.shared
    let text: AttributedString
    var scale: CGFloat = 1
    var bold = false
    var fixedSize: CGFloat?
    var fixedLineSpacing: CGFloat = 0

    init(_ text: String, scale: CGFloat = 1, bold: Bool = false, fixedSize: CGFloat? = nil, fixedLineSpacing: CGFloat = 0) {
        self.init(AttributedString(text), scale: scale, bold: bold, fixedSize: fixedSize, fixedLineSpacing: fixedLineSpacing)
    }

    init(_ text: AttributedString, scale: CGFloat = 1, bold: Bool = false, fixedSize: CGFloat? = nil, fixedLineSpacing: CGFloat = 0) {
        self.text = text; self.scale = scale; self.bold = bold
        self.fixedSize = fixedSize; self.fixedLineSpacing = fixedLineSpacing
    }

    var body: some View {
        Text(styled).lineSpacing(fixedSize == nil ? appearance.value.lineSpacing : fixedLineSpacing)
    }

    private var styled: AttributedString {
        let settings = appearance.value
        let pointSize = fixedSize ?? settings.size * scale
        var output = text
        // Resolve two fonts per update, not per character. Glyph fallback stays
        // with Core Text for IPA, emoji, and characters absent in a chosen font.
        let english = settings.font(chinese: false, size: pointSize)
        let chinese = settings.font(chinese: true, size: pointSize)
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var start = run.range.lowerBound
            while start < run.range.upperBound {
                let isChinese = Self.isChinese(text.characters[start])
                var end = text.characters.index(after: start)
                while end < run.range.upperBound, Self.isChinese(text.characters[end]) == isChinese {
                    end = text.characters.index(after: end)
                }
                var font = intent.contains(.code)
                    ? NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
                    : isChinese ? chinese : english
                if bold || intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                output[start..<end].font = Font(font)
                start = end
            }
        }
        return output
    }

    static func isChinese(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            switch $0.value {
            case 0x2E80...0x303F, 0x3100...0x31EF, 0x3400...0x9FFF,
                 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x323AF: return true
            default: return false
            }
        }
    }
}

/// Owned by each input coordinator. Applies attributes in place, without
/// replacing text, selection, undo state, or an IME's marked composition.
final class InputFontStyler {
    static let size: CGFloat = 16
    static let lineHeight: CGFloat = 22
    private weak var lastTarget: NSObject?
    private var lastText = ""
    private var lastEnglish: String?
    private var lastChinese: String?

    func invalidate() { lastTarget = nil }

    private func needsUpdate(_ target: NSObject, text: String, appearance: ReadingAppearance) -> Bool {
        guard lastTarget !== target || lastText != text || lastEnglish != appearance.english || lastChinese != appearance.chinese else { return false }
        lastTarget = target
        lastText = text
        lastEnglish = appearance.english
        lastChinese = appearance.chinese
        return true
    }

    func apply(to field: NSTextField, appearance: ReadingAppearance) {
        if let editor = field.currentEditor() as? NSTextView {
            apply(to: editor, appearance: appearance)
        } else if needsUpdate(field, text: field.stringValue, appearance: appearance) {
            field.attributedStringValue = attributed(field.stringValue, appearance: appearance)
        }
    }

    func apply(to editor: NSTextView, appearance: ReadingAppearance) {
        guard !editor.hasMarkedText(),
              needsUpdate(editor, text: editor.string, appearance: appearance),
              let storage = editor.textStorage else { return }
        let styled = attributed(editor.string, appearance: appearance)
        storage.beginEditing()
        styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length), options: []) { attributes, range, _ in
            storage.addAttributes(attributes, range: range)
        }
        storage.endEditing()
        let paragraph = Self.paragraphStyle()
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: appearance.font(chinese: false, size: Self.size),
                                  .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    private func attributed(_ text: String, appearance: ReadingAppearance) -> NSAttributedString {
        let english = appearance.font(chinese: false, size: Self.size)
        let chinese = appearance.font(chinese: true, size: Self.size)
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: english, .foregroundColor: NSColor.labelColor, .paragraphStyle: Self.paragraphStyle()
        ])
        // Group by script to keep the number of text attributes bounded by the
        // actual language transitions, rather than creating a run per glyph.
        var offset = 0
        var start = 0
        var previous: Bool?
        for character in text {
            let current = ReadingText.isChinese(character)
            if let previous, current != previous {
                result.addAttribute(.font, value: previous ? chinese : english,
                                    range: NSRange(location: start, length: offset - start))
                start = offset
            }
            previous = current
            offset += String(character).utf16.count
        }
        if let previous {
            result.addAttribute(.font, value: previous ? chinese : english,
                                range: NSRange(location: start, length: offset - start))
        }
        return result
    }

    private static func paragraphStyle() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return paragraph
    }
}
