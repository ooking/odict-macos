import AppKit
import SwiftUI

struct ReadingAppearance: Codable, Equatable {
    // Empty names mean system fonts; this also makes old or missing fonts safe.
    var english = ""
    var chinese = ""
    var size = 14.0
    var lineHeight = 1.6
    var useForLocalDictionaries = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case english, chinese, size, lineHeight, useForLocalDictionaries
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        english = try values.decodeIfPresent(String.self, forKey: .english) ?? ""
        chinese = try values.decodeIfPresent(String.self, forKey: .chinese) ?? ""
        size = try values.decodeIfPresent(Double.self, forKey: .size) ?? 14
        lineHeight = try values.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.6
        useForLocalDictionaries = try values.decodeIfPresent(Bool.self, forKey: .useForLocalDictionaries) ?? true
    }

    static let defaults = Self()
    static let sizeRange = 12.0...24.0
    static let lineHeightRange = 1.2...2.0

    var lineSpacing: CGFloat { CGFloat(size * (lineHeight - 1)) }

    func font(chinese: Bool, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let name = chinese ? self.chinese : english
        let base: NSFont
        if name == "system-serif", let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) {
            base = NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
        } else {
            base = name.isEmpty ? .systemFont(ofSize: size) : Self.installedFont(name, size: size) ?? .systemFont(ofSize: size)
        }
        return weight == .regular ? base : NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
    }

    static func title(for name: String, chinese: Bool) -> String {
        if name.isEmpty { return chinese ? "系统中文字体" : "系统字体（SF Pro）" }
        if name == "system-serif" { return "系统衬线字体（New York）" }
        guard let font = installedFont(name, size: 14) else { return "\(name)（不可用，使用系统字体）" }
        return font.familyName ?? name
    }

    static func installedFont(_ name: String, size: CGFloat) -> NSFont? {
        NSFont(name: name, size: size)
            ?? NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size)
    }

    /// Check the actual face's glyph coverage, without system fallback. Font
    /// objects are scoped to each check; only family names remain in the sheet.
    static func supportsChinese(_ name: String) -> Bool {
        autoreleasepool {
            guard let font = installedFont(name, size: 14) else { return false }
            return font.coveredCharacterSet.isSuperset(of: CharacterSet(charactersIn: "中文你好天地人山水"))
        }
    }

    /// Names enter CSS only after resolving through macOS, and are escaped as
    /// CSS strings. No downloaded fonts, scripts, or persistent font cache.
    var localCSS: String {
        guard useForLocalDictionaries else { return "" }
        func quoted(_ value: String) -> String {
            "\"" + value.unicodeScalars.map { scalar -> String in
                if scalar.value < 32 || "\"\\<>".unicodeScalars.contains(scalar) {
                    return "\\" + String(scalar.value, radix: 16) + " "
                }
                return String(scalar)
            }.joined() + "\""
        }
        let en = font(chinese: false, size: 14).fontName
        let zh = font(chinese: true, size: 14).fontName
        // System design fonts have private PostScript names; WebKit exposes
        // these through generic families rather than local font names.
        let englishFamily = english == "system-serif" ? "ui-serif, Georgia, serif"
            : english.isEmpty ? "-apple-system, sans-serif" : "\(quoted(en)), -apple-system, sans-serif"
        return """
        @font-face { font-family: ODictChinese; src: local(\(quoted(zh))); unicode-range: U+2E80-303F,U+3100-31EF,U+3400-9FFF,U+F900-FAFF,U+FE30-FE4F,U+FF00-FFEF,U+20000-323AF; }
        html, body {
          font-family: ODictChinese, \(englishFamily) !important;
          font-size: \(size)px !important;
        }
        """
    }
}

/// One small value is shared. Subscribers are restricted to reading content and
/// the appearance page; changes never restart lookup or AI requests.
final class ReadingAppearanceStore: ObservableObject {
    static let shared = ReadingAppearanceStore()
    private static let key = "readingAppearance.v1"
    @Published private(set) var value: ReadingAppearance

    private init() {
        let decoded = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(ReadingAppearance.self, from: $0) } ?? .defaults
        value = Self.validated(decoded)
    }

    func update(_ change: (inout ReadingAppearance) -> Void) {
        var next = value
        change(&next)
        next = Self.validated(next)
        guard next != value, let data = try? JSONEncoder().encode(next) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
        value = next
    }

    private static func validated(_ value: ReadingAppearance) -> ReadingAppearance {
        var value = value
        value.size = value.size.isFinite ? min(24, max(12, value.size)) : 14
        value.lineHeight = value.lineHeight.isFinite ? min(2, max(1.2, value.lineHeight)) : 1.6
        value.english = String(value.english.prefix(200))
        value.chinese = String(value.chinese.prefix(200))
        return value
    }
}
