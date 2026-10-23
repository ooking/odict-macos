#if DEBUG
import Foundation
import os

/// Developer-console diagnostics only. No HTML cache, file output or Release code.
enum LocalDictionaryDebug {
    private static let log = Logger(subsystem: "com.touchany.odict.mac", category: "LocalDictionaryDebug")
    private static let start = ProcessInfo.processInfo.systemUptime
    // Both stages by default. Use off/raw/document/full in the Run environment
    // to reduce output or explicitly remove the normal per-document print cap.
    private static let htmlMode = ProcessInfo.processInfo.environment["ODICT_LOCAL_HTML"] ?? "both"

    static func trace(_ event: String, articleID: UUID? = nil, _ detail: @autoclosure () -> String = "") {
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        let id = articleID?.uuidString.lowercased() ?? "-"
        let message = detail()
        log.debug("[ODict.Local] t=\(milliseconds)ms event=\(event, privacy: .public) article=\(id, privacy: .public) \(message, privacy: .public)")
    }

    static func html(_ html: String, stage: String, article: LocalArticle) {
        guard htmlMode != "off", htmlMode != "raw" || stage == "raw",
              htmlMode != "document" || stage == "document" else { return }
        let id = article.id.uuidString.lowercased()
        // OSLog truncates long messages. Print bounded UTF-8 chunks directly to
        // the debug console, with a shared article ID on every chunk. Never retain
        // an extra full Data copy or enqueue HTML on a background logging queue.
        var content = html
        content.withUTF8 { bytes in
            var limit = htmlMode == "full" ? bytes.count : min(bytes.count, 256 * 1024)
            while limit < bytes.count, limit > 0, bytes[limit] & 0xC0 == 0x80 { limit -= 1 }
            print("[ODict.Local] event=html.begin stage=\(stage) article=\(id) word=\(String(reflecting: article.word)) dictionary=\(String(reflecting: article.dictionary.name)) bytes=\(bytes.count) printedBytes=\(limit) truncated=\(limit < bytes.count)")
            var position = 0
            var part = 1
            while position < limit {
                var end = min(position + 2048, limit)
                while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end -= 1 }
                let chunk = String(decoding: bytes[position..<end], as: UTF8.self)
                // Prefix every nonempty line so Xcode's text filter keeps the
                // actual HTML as well as its headers. Normalize line endings for
                // console presentation only; the WebKit input stays untouched.
                let lines = chunk.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n").split(separator: "\n")
                for line in lines {
                    print("[ODict.Local] html.part stage=\(stage) article=\(id) part=\(part) \(line)")
                }
                position = end; part += 1
            }
            print("[ODict.Local] event=html.end stage=\(stage) article=\(id) parts=\(part - 1)")
        }
    }
}
#endif
