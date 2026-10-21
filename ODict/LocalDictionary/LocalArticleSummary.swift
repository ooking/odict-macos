import Foundation

/// Extract only marked Chinese definitions, never arbitrary article text or examples.
/// Runs on the local library actor without loading WebKit, scripts or resources.
enum LocalArticleSummary {
    private static func hasClass(_ value: String) -> String {
        "contains(concat(' ', normalize-space(@class), ' '), ' \(value) ')"
    }

    static func extract(from html: String) -> String? {
        // Bound the temporary DOM; unusually large articles still render normally.
        guard html.utf8.count <= 512 * 1024,
              html.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { return nil }
        // HTML tidy drops unknown elements such as Longman's <tran>. Preserve
        // that semantic marker on a standard tag in this temporary copy only.
        let normalized = html.replacingOccurrences(of: "<tran(?=[\\s>])",
                with: "<span data-odict-translation=\"1\"", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</tran\\s*>", with: "</span>", options: [.regularExpression, .caseInsensitive])
        guard let document = try? XMLDocument(xmlString: normalized,
                options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) else { return nil }

        let excluded = ["example", "x-g", "gloss", "collgloss", "ids-g", "id-g", "pvs-g", "pv-g"]
            .map(hasClass).joined(separator: " or ")
        let phraseSense = "(\(hasClass("sense")) and .//*[\(hasClass("lexunit"))])"
        let chinese = hasClass("oalecd8e_chn")
        let definition = hasClass("def")
        let oxfordDefinition = hasClass("def-g")
        let translation = hasClass("translation")
        let chineseDefinition = hasClass("chn")
        let selectors = [
            "//*[\(chinese)][ancestor::*[\(oxfordDefinition)]]",
            "//*[@data-odict-translation='1'][ancestor::*[\(definition)]]",
            "//*[\(chineseDefinition) or \(translation)][ancestor::*[\(definition) or \(oxfordDefinition)]]"
        ]
        for selector in selectors {
            let path = selector + "[not(ancestor-or-self::*[\(excluded) or \(phraseSense) or self::script or self::style or self::nav or @hidden or @aria-hidden='true'])]"
            guard let nodes = try? document.nodes(forXPath: path) else { continue }
            var meanings: [String] = []
            for node in nodes {
                let text = String((node.stringValue ?? "").prefix(512))
                    .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                guard text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }),
                      !meanings.contains(text) else { continue }
                meanings.append(text)
                if meanings.count == 2 { break }
            }
            if !meanings.isEmpty { return String(meanings.joined(separator: "；").prefix(240)) }
        }
        return nil
    }
}
