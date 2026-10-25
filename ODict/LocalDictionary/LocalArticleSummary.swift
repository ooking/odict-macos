import Foundation

/// A bounded, script-free DOM used only for history metadata. Never rewrites MDX.
/// Explicit fields → external dictionary rules → legacy adapters → semantic fallback.
enum LocalArticleSummary {
    struct Rules: Decodable {
        let version: Int
        let definitionPaths: [String]
        var excludedPaths: [String] = []

        private enum CodingKeys: String, CodingKey { case version, definitionPaths, excludedPaths }
        init(version: Int = 1, definitionPaths: [String], excludedPaths: [String] = []) {
            self.version = version; self.definitionPaths = definitionPaths; self.excludedPaths = excludedPaths
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            definitionPaths = try values.decode([String].self, forKey: .definitionPaths)
            excludedPaths = try values.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
        }
        var isValid: Bool {
            version == 1 && definitionPaths.count <= 16 && excludedPaths.count <= 16
                && (definitionPaths + excludedPaths).allSatisfy { !$0.isEmpty && $0.utf8.count <= 2048 }
        }
    }

    static let rulesName = "odict-summary.json"
    static func loadRules(in folder: URL) -> Rules? {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(rulesName).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"),
              let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              properties.isRegularFile == true, (properties.fileSize ?? Int.max) <= 64 * 1024,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024 + 1), data.count <= 64 * 1024,
              let rules = try? JSONDecoder().decode(Rules.self, from: data), rules.isValid else { return nil }
        return rules
    }

    private static func hasClass(_ value: String) -> String {
        "contains(concat(' ', normalize-space(@class), ' '), ' \(value) ')"
    }
    private static func marker(_ value: String) -> String {
        "(\(hasClass(value)) or @data-odict-tag='\(value)')"
    }

    static func extract(from html: String, rules: Rules? = nil) -> String? {
        guard html.utf8.count <= 512 * 1024, !Task.isCancelled,
              html.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { return nil }
        guard let document = try? XMLDocument(xmlString: normalizedHTML(html),
                options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) else { return nil }

        let excluded = ["example", "examples", "x", "x-g", "x-gs", "x-g-blk", "gloss", "collgloss",
                        "template", "script", "style", "nav", "ids-g", "id-g", "idm-g", "idm-gs", "idm-blk", "pvs-g", "pv-g", "pv-gs", "pv-blk", "deq"]
            .map(marker).joined(separator: " or ")
        let phraseSense = "(\(hasClass("sense")) and .//*[\(marker("lexunit"))])"
        // Remove excluded subtrees before collecting stringValue: nested examples,
        // scripts and hidden translations must never leak into a selected definition.
        let inlineStyle = "translate(translate(@style, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), ' \t\r\n', '')"
        let removed = "//*[\(excluded) or \(phraseSense) or self::script or self::style or self::nav or self::template or @hidden or @aria-hidden='true' or contains(\(inlineStyle), 'display:none') or contains(\(inlineStyle), 'visibility:hidden')]"
        for node in (try? document.nodes(forXPath: removed)) ?? [] { node.detach() }
        if let rules, rules.isValid {
            for path in rules.excludedPaths {
                for node in (try? document.nodes(forXPath: path)) ?? [] { node.detach() }
            }
        }
        let definition = "\(marker("def")) or \(marker("def-g")) or \(marker("definition")) or @itemprop='definition'"
        let chinese = "\(marker("chn")) or \(marker("translation")) or \(marker("tran")) or \(hasClass("oalecd8e_chn")) or starts-with(@lang, 'zh') or starts-with(@xml:lang, 'zh')"
        let bing = "[ancestor::*[\(hasClass("dcb"))]][ancestor::*[\(hasClass("gdc"))]][ancestor::*[@id='ecdict']]"
        let customPaths = rules.flatMap { $0.isValid ? $0.definitionPaths : nil } ?? []
        let paths = [
            "//*[@data-odict-summary]",
            "//meta[@name='odict-summary']/@content"
        ] + customPaths + [
            "//*[\(hasClass("oalecd8e_chn"))][ancestor::*[\(marker("def-g"))]]",
            "//*[\(marker("tran"))][ancestor::*[\(marker("def"))]]",
            "//*[\(chinese)][ancestor::*[\(definition)]]",
            "//*[\(hasClass("dcn"))]" + bing,
            "//*[\(hasClass("dne"))]" + bing,
            // Conservative fallback: only definition-marked text, never the body.
            "//*[\(definition)]"
        ]
        for path in paths {
            guard !Task.isCancelled else { return nil }
            guard let nodes = try? document.nodes(forXPath: path) else { continue }
            var meanings: [String] = []
            for node in nodes.prefix(128) {
                let text = clean(node.stringValue ?? "")
                guard text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }),
                      !meanings.contains(text) else { continue }
                meanings.append(text)
                if meanings.count == 2 { break }
            }
            if !meanings.isEmpty { return String(meanings.joined(separator: "；").prefix(240)) }
        }
        return nil
    }

    private static func clean(_ value: String) -> String {
        let bounded = String(value.prefix(2048))
        let visible = bounded.unicodeScalars.filter {
            ![0x200B, 0x200C, 0x200D, 0xFEFF].contains($0.value)
                && (!CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0))
        }
        return String(String.UnicodeScalarView(visible)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// libxml's HTML tidy discards unknown tags. Preserve their names on spans in
    /// this temporary copy, so any dictionary's custom vocabulary remains queryable.
    private static let standardTags = Set("html head body title meta link div span p a b i em strong u s small sub sup br hr ul ol li dl dt dd table thead tbody tfoot tr th td caption col colgroup h1 h2 h3 h4 h5 h6 blockquote q pre code img audio video source picture input button select option label form nav main article section aside header footer details summary figure figcaption ruby rt rp wbr abbr cite time mark svg path".split(separator: " ").map(String.init))
    private static let tagPattern = try? NSRegularExpression(
        pattern: "<(/?)([A-Za-z][A-Za-z0-9:_-]*)(?=[\\s/>])((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>")

    private static func normalizedHTML(_ html: String) -> String {
        let stripped = html.replacingOccurrences(of: "(?is)<!--.*?-->|<(script|style)\\b[^>]*>.*?</\\1\\s*>",
            with: "", options: .regularExpression)
        guard let regex = tagPattern else { return stripped }
        let source = stripped as NSString
        var output = ""
        output.reserveCapacity(stripped.utf8.count)
        var copied = 0
        // Append in source order, avoiding repeated shifts of the entire HTML.
        for match in regex.matches(in: stripped, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 2)).lowercased()
            guard !standardTags.contains(name) else { continue }
            output += source.substring(with: NSRange(location: copied, length: match.range.location - copied))
            let closing = source.substring(with: match.range(at: 1)) == "/"
            var attributes = source.substring(with: match.range(at: 3))
            let selfClosing = attributes.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
            if selfClosing, let slash = attributes.lastIndex(of: "/") { attributes.removeSubrange(slash...) }
            output += closing ? "</span>" : "<span data-odict-tag='\(name)'\(attributes)>" + (selfClosing ? "</span>" : "")
            copied = NSMaxRange(match.range)
        }
        output += source.substring(from: copied)
        return output
    }
}
