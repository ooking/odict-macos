import Foundation

enum LocalArticleDocumentChecks {
    static func run() throws {
        func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw NSError(domain: "LocalArticleDocumentChecks", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let script = #"<script>const sample = '<body class="literal">'; const css = '</head>'; </script>"#
        let comment = "<!-- <html><body>comment</body></html> -->"
        let custom = #"<x-entry data-sample="<body>"><h1 title="x > <head>">词条</h1><tran>释义</tran></x-entry>"#
        let source = "<!DOCTYPE html><HTML lang='zh'><HEAD><link href='dict.css' rel='stylesheet'>"
            + script + "</HEAD><BODY class='dictionary' data-x='>'>" + comment + custom
            + "<textarea><body>literal</body></textarea></BODY></HTML>"
        let document = try LocalArticleDocument.make(html: source, footer: "<footer>source</footer>")
        try expect(document.contains("<HTML lang='zh'><head>"), "Preserve primary html attributes")
        try expect(document.contains("<BODY class='dictionary' data-x='>'>"), "Preserve quoted body attributes")
        try expect(document.contains(script) && document.contains(comment) && document.contains(custom),
                   "Do not rewrite script strings, comments, custom elements or quoted attributes")
        try expect(document.contains("<textarea><body>literal</body></textarea>"), "Preserve RCDATA")
        try expect(!document.contains("</BODY>") && !document.contains("</HTML>"), "Remove embedded closing wrappers")
        try expect(document.components(separatedBy: "<!doctype html>").count == 2, "One transport doctype")

        let deferred = "<script defer src='dictionary.js'></script>"
        let second = try LocalArticleDocument.make(html: source + "<html><head>" + deferred
            + "</head><body><div id='second'>second</div></body></html>", footer: "")
        let suffix = "<style id=\"odict-local-overrides\"></style>"
            + "<script defer src=\"/odict-overrides.js\"></script></body></html>"
        try expect(second.hasSuffix(suffix), "Inline final CSS and parser-inserted JS follow all dictionary content")
        let css = #".x::before { content: '</STYLE>'; } @media (width < 600px) { .x { color: red; } }"#
        let styled = try LocalArticleDocument.make(html: "<p>text</p>", footer: "", overridesCSS: css)
        try expect(styled.contains(#"content: '\3C /STYLE>'"#), "Safely embed CSS without changing closing-tag casing")
        try expect(styled.contains("width < 600px"), "Preserve CSS comparison operators")
        try expect(!styled.contains("href=\"/odict-overrides.css\""), "Final styles must not depend on a late stylesheet request")
        try expect(second.contains(deferred), "Preserve dictionary deferred scripts")
        let duplicate = try LocalArticleDocument.make(html: script + script, footer: "")
        try expect(duplicate.components(separatedBy: script).count == 3, "Do not silently deduplicate scripts")
        let inert = "<template><html><body class='inert'>example</body></html></template>"
        let template = try LocalArticleDocument.make(html: inert + "<body class='actual'>text</body>", footer: "")
        try expect(template.contains(inert) && template.contains("<body class='actual'>"), "Inert templates cannot supply document attributes")
        for malformed in ["<body x='unterminated", "<script>unterminated", "<!-- unterminated"] {
            do {
                _ = try LocalArticleDocument.make(html: malformed, footer: "")
                throw NSError(domain: "LocalArticleDocumentChecks", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Malformed HTML must not swallow transport resources"])
            } catch is LocalDictionaryError { }
        }
        let cases: [(String, LocalArticleLink.Target?)] = [
            ("entry://#sense_2", .anchor("sense_2")),
            ("entry://#%E4%B8%AD%E6%96%87", .anchor("中文")),
            ("entry://C%23", .word("C#")),
            ("entry://People#sense_2", .word("People")),
            ("gdlookup://localhost/hello%20world?gdanchor=test", .word("hello world")),
            ("https://example.com/", nil)
        ]
        for (value, target) in cases {
            try expect(LocalArticleLink.target(URL(string: value)!) == target, "Internal link: \(value)")
        }
        let page = URL(string: "odict-local://current/__odict_article.html")!
        try expect(LocalArticleLink.isSameDocument(URL(string: page.absoluteString + "#sense"), as: page), "Fragment remains current document")
        try expect(!LocalArticleLink.isSameDocument(URL(string: "odict-local://previous/__odict_article.html"), as: page), "Reject old origin")
        let payload = "quote\"; alert('injected'); //"
        let js = LocalArticleLink.anchorScript(payload)!
        let literal = String(js.dropFirst("window.location.hash = ".count).dropLast("[0];".count))
        let decoded = try JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String]
        try expect(decoded == [payload], "Anchor text remains serialized data")
    }
}
