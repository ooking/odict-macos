import SwiftUI

/// Native Markdown presentation: no WebView, remote image loading, or executable HTML.
struct AIMarkdownView: View {
    private let blocks: [AIMarkdownBlock]
    init(markdown: String) { blocks = AIMarkdownParser.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                switch block.content {
                case .heading(let level, let text):
                    Text(text).font(.system(size: level == 1 ? 23 : level == 2 ? 19 : 16, weight: .semibold))
                        .textSelection(.enabled).padding(.top, block.id == 0 ? 0 : 5)
                case .paragraph(let text):
                    prose(text)
                case .listItem(let marker, let indent, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).foregroundColor(.secondary)
                        prose(text)
                    }.padding(.leading, CGFloat(indent) * 10)
                case .quote(let text):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.35)).frame(width: 3)
                        prose(text).foregroundColor(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                case .code(let language, let code):
                    VStack(alignment: .leading, spacing: 6) {
                        if !language.isEmpty { Text(language).font(AppTypography.caption).foregroundColor(.secondary) }
                        ScrollView(.horizontal) {
                            Text(code).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                .padding(.bottom, 4)
                        }
                    }.padding(10).background(Color.primary.opacity(0.045)).cornerRadius(7)
                case .rule:
                    Divider()
                case .table(let header, let rows):
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            tableRow(header, isHeader: true)
                            Divider()
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                tableRow(row)
                                Divider().opacity(0.5)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
    private func prose(_ text: AttributedString) -> some View {
        Text(text).font(AppTypography.body).lineSpacing(5).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func tableRow(_ values: [AttributedString], isHeader: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value).font(.system(size: 14, weight: isHeader ? .semibold : .regular)).textSelection(.enabled)
                    .frame(width: 140, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 7)
    }
}

private struct AIMarkdownBlock: Identifiable {
    enum Content {
        case heading(Int, AttributedString), paragraph(AttributedString)
        case listItem(String, Int, AttributedString), quote(AttributedString)
        case code(String, String), rule, table([AttributedString], [[AttributedString]])
    }
    let id: Int
    let content: Content
}

/// Linear block parsing with a bounded number of native views. Excess blocks remain readable text.
private enum AIMarkdownParser {
    static func parse(_ markdown: String) -> [AIMarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var blocks: [AIMarkdownBlock] = []
        var index = 0
        func append(_ content: AIMarkdownBlock.Content) {
            blocks.append(AIMarkdownBlock(id: blocks.count, content: content))
        }
        while index < lines.count {
            let line = trim(lines[index])
            if line.isEmpty { index += 1; continue }
            if blocks.count >= 255 {
                append(.paragraph(inline(lines[index...].joined(separator: "\n"))))
                break
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let fence = String(line.prefix(3)), language = trim(String(line.dropFirst(3)))
                index += 1
                var code: [String] = []
                while index < lines.count, !trim(lines[index]).hasPrefix(fence) {
                    code.append(lines[index]); index += 1
                }
                if index < lines.count { index += 1 }
                append(.code(language, code.joined(separator: "\n")))
            } else if let heading = heading(line) {
                append(.heading(heading.0, inline(heading.1))); index += 1
            } else if isRule(line) {
                append(.rule); index += 1
            } else if line.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count, trim(lines[index]).hasPrefix(">") {
                    quote.append(trim(String(trim(lines[index]).dropFirst())))
                    index += 1
                }
                append(.quote(inline(quote.joined(separator: "\n"))))
            } else if let item = listItem(line) {
                let indent = min(6, lines[index].prefix(while: \.isWhitespace).count / 2)
                append(.listItem(item.0, indent, inline(item.1))); index += 1
            } else if index + 1 < lines.count, line.contains("|"), isTableSeparator(lines[index + 1]) {
                let header = cells(line)
                guard header.count <= 8 else { append(.paragraph(inline(line))); index += 1; continue }
                index += 2
                var rows: [[AttributedString]] = []
                while index < lines.count, lines[index].contains("|"), !trim(lines[index]).isEmpty, rows.count < 50 {
                    let row = cells(lines[index])
                    if row.count > header.count { break }
                    rows.append((row + Array(repeating: "", count: header.count - row.count)).map(inline))
                    index += 1
                }
                append(.table(header.map(inline), rows))
            } else {
                var paragraph = [lines[index]]
                index += 1
                while index < lines.count {
                    let next = trim(lines[index])
                    if next.isEmpty || isSpecial(next) || (index + 1 < lines.count && next.contains("|") && isTableSeparator(lines[index + 1])) { break }
                    paragraph.append(lines[index]); index += 1
                }
                append(.paragraph(inline(paragraph.joined(separator: "\n"))))
            }
        }
        return blocks
    }
    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func heading(_ text: String) -> (Int, String)? {
        let count = text.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), text.dropFirst(count).first?.isWhitespace == true else { return nil }
        return (count, trim(String(text.dropFirst(count))))
    }
    private static func isRule(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }
    private static func listItem(_ text: String) -> (String, String)? {
        for prefix in ["- ", "* ", "+ "] where text.hasPrefix(prefix) { return ("•", String(text.dropFirst(2))) }
        let digits = text.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 6 else { return nil }
        let tail = text.dropFirst(digits.count)
        guard tail.hasPrefix(". ") || tail.hasPrefix(") ") else { return nil }
        return (String(digits) + ".", String(tail.dropFirst(2)))
    }
    private static func cells(_ text: String) -> [String] {
        var value = trim(text)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.components(separatedBy: "|").map(trim)
    }
    private static func isTableSeparator(_ text: String) -> Bool {
        let values = cells(text)
        return !values.isEmpty && values.count <= 8 && values.allSatisfy { value in
            let clean = value.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return clean.count >= 3 && clean.allSatisfy { $0 == "-" }
        }
    }
    private static func isSpecial(_ text: String) -> Bool {
        text.hasPrefix("```") || text.hasPrefix("~~~") || text.hasPrefix(">") || heading(text) != nil || listItem(text) != nil || isRule(text)
    }
}
