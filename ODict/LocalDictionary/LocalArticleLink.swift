import Foundation

enum LocalArticleLink {
    enum Target: Equatable {
        case anchor(String)
        case word(String)
    }

    static func target(_ url: URL) -> Target? {
        guard let scheme = url.scheme?.lowercased(), ["entry", "bword", "gdlookup"].contains(scheme),
              let colon = url.absoluteString.firstIndex(of: ":") else { return nil }
        var raw = String(url.absoluteString[url.absoluteString.index(after: colon)...])
        if raw.hasPrefix("//") { raw.removeFirst(2) }
        // Split before decoding: an encoded '#' can be part of a headword.
        let pieces = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        var word = String(pieces[0])
        if scheme == "gdlookup" {
            word = String(word.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
            if word.hasPrefix("localhost/") { word.removeFirst("localhost/".count) }
        }
        guard let decoded = word.removingPercentEncoding else { return nil }
        if !decoded.isEmpty { return decoded.count <= 255 ? .word(decoded) : nil }
        guard pieces.count == 2, let anchor = String(pieces[1]).removingPercentEncoding,
              anchor.utf8.count <= 4096 else { return nil }
        return .anchor(anchor)
    }

    static func isSameDocument(_ url: URL?, as page: URL) -> Bool {
        guard let url else { return false }
        var lhs = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var rhs = URLComponents(url: page, resolvingAgainstBaseURL: false)
        lhs?.fragment = nil; rhs?.fragment = nil
        return lhs != nil && lhs == rhs
    }

    static func anchorScript(_ anchor: String) -> String? {
        // Serialize data instead of interpolating dictionary text into JS source.
        guard anchor.utf8.count <= 4096,
              let data = try? JSONSerialization.data(withJSONObject: [anchor]),
              let literal = String(data: data, encoding: .utf8) else { return nil }
        return "window.location.hash = \(literal)[0];"
    }
}
