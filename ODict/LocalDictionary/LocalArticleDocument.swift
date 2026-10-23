import Foundation

/// Transport-only normalization. Dictionary markup, scripts and CSS retain their
/// order and bytes, apart from document wrappers and obsolete plaintext elements.
enum LocalArticleDocument {
    static let scheme = "odict-local"

    static func make(article: LocalArticle, overridesCSS: String) throws -> String {
        try make(html: article.html, footer: sourceFooter(article), overridesCSS: overridesCSS)
    }

    static func make(html: String, footer: String, overridesCSS: String = "") throws -> String {
        guard html.utf8.count <= MDXCompression.limit else {
            throw LocalDictionaryError.invalid("HTML 内容过大")
        }
        var scanner = ShellScanner(html)
        let content = try scanner.scan()
        let policy = "default-src 'none'; img-src \(scheme): data:; style-src \(scheme): 'unsafe-inline'; font-src \(scheme): data:; script-src \(scheme): 'unsafe-inline'; media-src \(scheme): data:; connect-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"
        // Final CSS is part of the document, after dictionary CSS: never expose a
        // frame that still needs an external override request. Relative resource
        // URLs have the same base here as /odict-overrides.css (both at origin root).
        // The parser-inserted deferred override follows dictionary deferred scripts.
        return "<!doctype html>" + (scanner.htmlTag ?? "<html>")
            + "<head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
            + "<style>:where(body) { font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', 'PingFang SC', sans-serif; font-size: 15px; line-height: 1.6; }</style></head>"
            + (scanner.bodyTag ?? "<body>") + content + footer
            + "<style id=\"odict-local-overrides\">" + escapeStyleText(overridesCSS) + "</style>"
            + "<script defer src=\"/odict-overrides.js\"></script></body></html>"
    }

    /// Escape only the HTML closing-tag opener, using a CSS escape that preserves
    /// the original value and casing. Do not rewrite arbitrary '<' CSS operators.
    private static func escapeStyleText(_ css: String) -> String {
        var output = ""
        output.reserveCapacity(css.utf8.count)
        var start = css.startIndex
        while let match = css.range(of: "</style", options: .caseInsensitive, range: start..<css.endIndex) {
            output.append(contentsOf: css[start..<match.lowerBound])
            output.append("\\3C ")
            start = css.index(after: match.lowerBound)
        }
        output.append(contentsOf: css[start...])
        return output
    }

    /// A lexical scanner rather than HTML tidy or global regex replacements:
    /// neither unknown dictionary tags nor '<body>' inside JS/text are rewritten.
    private struct ShellScanner {
        let bytes: [UInt8]
        var htmlTag: String?
        var bodyTag: String?
        private static let textElements: Set<String> = [
            "script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "noscript"
        ]

        init(_ html: String) { bytes = Array(html.utf8) }

        mutating func scan() throws -> String {
            var output: [UInt8] = []
            output.reserveCapacity(bytes.count)
            var position = 0
            var copied = 0
            var templateDepth = 0
            while position < bytes.count {
                if position % 4096 == 0 { try Task.checkCancellation() }
                guard bytes[position] == 60 else { position += 1; continue }
                if matches("<!--", at: position) {
                    position += 4
                    while position < bytes.count, !matches("-->", at: position) {
                        if position % 4096 == 0 { try Task.checkCancellation() }
                        position += 1
                    }
                    guard position < bytes.count else { throw LocalDictionaryError.invalid("HTML 注释未闭合") }
                    position += 3
                    continue
                }
                if matches("<!doctype", at: position), boundary(at: position + 9) {
                    guard let end = try tagEnd(from: position + 9, declaration: true) else {
                        throw LocalDictionaryError.invalid("HTML 文档声明未闭合")
                    }
                    output.append(contentsOf: bytes[copied..<position])
                    position = end; copied = end
                    continue
                }
                var cursor = position + 1
                let closing = cursor < bytes.count && bytes[cursor] == 47
                if closing { cursor += 1 }
                let nameStart = cursor
                guard cursor < bytes.count, isLetter(bytes[cursor]) else {
                    position += 1; continue
                }
                // Custom elements, h1, SVG names etc. still need their quoted
                // attributes skipped, even though their names are not rewritten.
                while cursor < bytes.count, !boundary(at: cursor) { cursor += 1 }
                guard let end = try tagEnd(from: cursor) else {
                    throw LocalDictionaryError.invalid("HTML 标签未闭合")
                }
                let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self).lowercased()
                if name == "template" {
                    templateDepth = closing ? max(0, templateDepth - 1) : templateDepth + 1
                }
                if templateDepth == 0, name == "html" || name == "head" || name == "body" {
                    if !closing {
                        let tag = String(decoding: bytes[position..<end], as: UTF8.self)
                        if name == "html", htmlTag == nil { htmlTag = tag }
                        if name == "body", bodyTag == nil { bodyTag = tag }
                    }
                    output.append(contentsOf: bytes[copied..<position])
                    copied = end
                }
                let tagStart = position
                position = end
                if !closing, name == "plaintext" {
                    // Plaintext consumes the rest of an HTML document. Close it
                    // by escaping its text so transport resources remain markup.
                    output.append(contentsOf: bytes[copied..<tagStart])
                    output.append(contentsOf: "<pre>".utf8)
                    let text = String(decoding: bytes[position...], as: UTF8.self)
                        .replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "<", with: "&lt;")
                    output.append(contentsOf: text.utf8)
                    output.append(contentsOf: "</pre>".utf8)
                    copied = bytes.count; position = bytes.count
                } else if !closing, Self.textElements.contains(name) {
                    let close = "</" + name
                    while position < bytes.count {
                        if position % 4096 == 0 { try Task.checkCancellation() }
                        if bytes[position] == 60, matches(close, at: position), boundary(at: position + close.utf8.count) { break }
                        position += 1
                    }
                    guard position < bytes.count else {
                        throw LocalDictionaryError.invalid("HTML 的 \(name) 元素未闭合")
                    }
                }
            }
            output.append(contentsOf: bytes[copied...])
            try Task.checkCancellation()
            return String(decoding: output, as: UTF8.self)
        }

        private func matches(_ ascii: String, at position: Int) -> Bool {
            guard position + ascii.utf8.count <= bytes.count else { return false }
            return ascii.utf8.enumerated().allSatisfy { offset, byte in
                let value = bytes[position + offset]
                return (65...90).contains(value) ? value + 32 == byte : value == byte
            }
        }
        private func isLetter(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte)
        }
        private func boundary(at position: Int) -> Bool {
            guard position < bytes.count else { return false }
            switch bytes[position] {
            case 9, 10, 12, 13, 32, 47, 62: return true
            default: return false
            }
        }
        /// Quoted '>' and a doctype internal subset do not terminate a tag.
        private func tagEnd(from start: Int, declaration: Bool = false) throws -> Int? {
            var quote: UInt8?
            var brackets = 0
            var position = start
            while position < bytes.count {
                if position % 4096 == 0 { try Task.checkCancellation() }
                let byte = bytes[position]
                if let current = quote {
                    if byte == current { quote = nil }
                } else if byte == 34 || byte == 39 { quote = byte }
                else if declaration && byte == 91 { brackets += 1 }
                else if declaration && byte == 93 { brackets = max(0, brackets - 1) }
                else if byte == 62 && brackets == 0 { return position + 1 }
                position += 1
            }
            return nil
        }
    }

    private static func sourceFooter(_ article: LocalArticle) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        }
        var lines = ["来源：\(article.dictionary.name) · 本地"]
        if !article.correspondingHeadwords.isEmpty {
            lines.append("\(article.word) → \(article.correspondingHeadwords.joined(separator: "、"))（词典对应词条）")
        }
        let content = lines.map { "<div>\(escape($0))</div>" }.joined()
        return "<footer id=\"odict-source-footer\" style=\"display:block;clear:both;margin-top:24px;padding:12px 0 4px;border-top:1px solid var(--odict-rule,rgba(128,128,128,.25));font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:12px;line-height:1.6;font-weight:400;color:var(--odict-secondary,GrayText);overflow-wrap:anywhere;\">" + content + "</footer>"
    }
}
