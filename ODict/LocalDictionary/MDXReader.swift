import Foundation
import CoreFoundation

final class MDXHeader: NSObject, XMLParserDelegate {
    var attributes: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if attributes.isEmpty { attributes = attributeDict }
    }
    static func read(_ data: Data) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf16LittleEndian) else {
            throw LocalDictionaryError.invalid("文件头编码")
        }
        let parser = XMLParser(data: Data(text.trimmingCharacters(in: .controlCharacters).utf8))
        let delegate = MDXHeader()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !delegate.attributes.isEmpty else { throw LocalDictionaryError.invalid("XML 文件头") }
        return delegate.attributes
    }
}

/// Confined to LocalDictionaryLibrary's actor. Only built-in block directories
/// remain resident; key blocks and record blocks are read on demand, never indexed to disk.
final class MDXReader {
    struct Key { let word: String; let offset: UInt64 }
    private struct KeyBlock {
        let first: String, last: String
        let position: UInt64
        let compressed: Int, expanded: Int
    }
    private struct RecordBlock {
        let position: UInt64, start: UInt64, end: UInt64
        let compressed: Int, expanded: Int
    }
    let url: URL
    let title: String
    private let file: FileHandle
    private let fileSize: UInt64
    private let encoding: String.Encoding
    private let unit: Int
    private let resource: Bool
    private let caseSensitive: Bool
    private let strip: Bool
    private var keyBlocks: [KeyBlock] = []
    private var recordBlocks: [RecordBlock] = []
    private var keyCache: (Int, [Key])?
    private var recordCache: (Int, Data)?
    private var totalRecords: UInt64 = 0
    var residentBudget: Int {
        keyBlocks.reduce(0) { $0 + $1.first.utf8.count + $1.last.utf8.count + 96 }
            + recordBlocks.count * 64 + 2 * 1024 * 1024
    }

    init(url: URL) throws {
        self.url = url
        resource = url.pathExtension.lowercased() == "mdd"
        file = try FileHandle(forReadingFrom: url)
        fileSize = try file.seekToEnd()
        try file.seek(toOffset: 0)
        let lengthData = try file.read(upToCount: 4) ?? Data()
        var prefix = MDXCursor(lengthData)
        let headerLength = try Self.size(prefix.number(4), limit: 1024 * 1024)
        let headerData = try file.read(upToCount: headerLength) ?? Data()
        guard headerData.count == headerLength else { throw LocalDictionaryError.invalid("文件头不完整") }
        let attributes = try MDXHeader.read(headerData)
        var headerChecksum = MDXCursor(try file.read(upToCount: 4) ?? Data())
        let headerChecksumBytes = try headerChecksum.take(4)
        let storedChecksum = Array(headerChecksumBytes).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard MDXCompression.checksum(headerData) == storedChecksum else { throw LocalDictionaryError.invalid("文件头校验失败") }
        guard attributes["GeneratedByEngineVersion"] == "2.0" else {
            throw LocalDictionaryError.unsupported("当前支持 MDX/MDD 2.0")
        }
        let encryption = attributes["Encrypted"] ?? "0"
        let encrypted = encryption.lowercased() == "no" ? 0 : (Int(encryption) ?? -1)
        guard encrypted == 0 || encrypted == 2 else {
            throw LocalDictionaryError.unsupported("需要密码或注册信息的加密方式")
        }
        title = attributes["Title"].flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        let name = resource ? "UTF-16" : (attributes["Encoding"] ?? "UTF-8").uppercased()
        switch name {
        case "UTF-8", "UTF8": encoding = .utf8
        case "UTF-16", "UTF-16LE": encoding = .utf16LittleEndian
        case "GBK", "GB2312", "GB18030":
            encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "BIG5":
            encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        default: throw LocalDictionaryError.unsupported("编码 \(name)")
        }
        unit = encoding == .utf16LittleEndian ? 2 : 1
        caseSensitive = attributes["KeyCaseSensitive"]?.lowercased() == "yes"
        strip = !resource && attributes["StripKey"]?.lowercased() == "yes"
        // Compact dictionaries with a nonempty substitution table need a dedicated
        // format decoder. Never silently render their encoded markers as definitions.
        if attributes["StyleSheet"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            throw LocalDictionaryError.unsupported("内嵌 StyleSheet 替换表")
        }
        let keywordHeader = try read(at: UInt64(8 + headerLength), count: 44)
        var header = MDXCursor(keywordHeader)
        let keyCount = try Self.size(header.number(8), limit: 200_000)
        _ = try header.number(8) // entry count
        let infoExpanded = try Self.size(header.number(8))
        let infoCompressed = try Self.size(header.number(8))
        let keysLength = try header.number(8)
        let keywordChecksum = try header.number(4)
        guard MDXCompression.checksum(Data(keywordHeader.prefix(40))) == keywordChecksum else {
            throw LocalDictionaryError.invalid("词头目录校验失败")
        }
        let infoPosition = UInt64(8 + headerLength + 44)
        var infoData = try read(at: infoPosition, count: infoCompressed)
        if encrypted == 2 { infoData = try MDXCompression.decryptIndex(infoData) }
        var info = MDXCursor(try MDXCompression.decode(infoData, expected: infoExpanded))
        var keyPosition = infoPosition + UInt64(infoCompressed)
        let recordPosition = try Self.add(keyPosition, keysLength)
        for _ in 0..<keyCount {
            try Task.checkCancellation()
            _ = try info.number(8)
            let firstSize = try Self.size(info.number(2), limit: 65_535)
            let first = try text(info.take(firstSize * unit))
            _ = try info.take(unit)
            let lastSize = try Self.size(info.number(2), limit: 65_535)
            let last = try text(info.take(lastSize * unit))
            _ = try info.take(unit)
            let compressed = try Self.size(info.number(8))
            let expanded = try Self.size(info.number(8))
            keyBlocks.append(KeyBlock(first: normalized(first), last: normalized(last), position: keyPosition,
                                      compressed: compressed, expanded: expanded))
            keyPosition = try Self.add(keyPosition, UInt64(compressed))
        }
        guard keyPosition == recordPosition, info.remaining == 0 else { throw LocalDictionaryError.invalid("词头块目录") }
        var records = MDXCursor(try read(at: recordPosition, count: 32))
        let count = try Self.size(records.number(8), limit: 500_000)
        _ = try records.number(8)
        let directorySize = try Self.size(records.number(8))
        let compressedTotal = try records.number(8)
        guard directorySize == count * 16 else { throw LocalDictionaryError.invalid("正文块目录大小") }
        var directory = MDXCursor(try read(at: try Self.add(recordPosition, 32), count: directorySize))
        var position = try Self.add(recordPosition, UInt64(32 + directorySize))
        let end = try Self.add(position, compressedTotal)
        guard end <= fileSize else { throw LocalDictionaryError.invalid("正文越过文件末尾") }
        for _ in 0..<count {
            try Task.checkCancellation()
            let compressed = try Self.size(directory.number(8))
            let expanded = try Self.size(directory.number(8))
            let next = try Self.add(totalRecords, UInt64(expanded))
            recordBlocks.append(RecordBlock(position: position, start: totalRecords, end: next,
                                            compressed: compressed, expanded: expanded))
            totalRecords = next
            position = try Self.add(position, UInt64(compressed))
        }
        guard position == end else { throw LocalDictionaryError.invalid("正文块长度") }
    }
    deinit { try? file.close() }

    private static func size(_ value: UInt64, limit: Int = MDXCompression.limit) throws -> Int {
        guard value <= UInt64(limit) else { throw LocalDictionaryError.invalid("词典数据超出读取上限") }
        return Int(value)
    }
    private static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw LocalDictionaryError.invalid("位置溢出") }
        return sum
    }
    private func read(at position: UInt64, count: Int) throws -> Data {
        try Task.checkCancellation()
        guard count >= 0, count <= MDXCompression.limit,
              position <= fileSize, UInt64(count) <= fileSize - position else {
            throw LocalDictionaryError.invalid("读取位置超出文件")
        }
        try file.seek(toOffset: position)
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else { throw LocalDictionaryError.invalid("文件读取不完整") }
        return data
    }
    private func text(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: encoding) else { throw LocalDictionaryError.invalid("词典文字编码") }
        return text.trimmingCharacters(in: .controlCharacters)
    }
    private func normalized(_ value: String) -> String {
        var key = resource ? value.replacingOccurrences(of: "/", with: "\\") : value
        if resource && !key.hasPrefix("\\") { key = "\\" + key }
        if strip { key = String(key.unicodeScalars.filter { !CharacterSet(charactersIn: "()., '/\\@_-").contains($0) }) }
        return caseSensitive ? key : key.lowercased()
    }
    private func less(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
    private func keys(_ block: Int) throws -> [Key] {
        if let cache = keyCache, cache.0 == block { return cache.1 }
        let info = keyBlocks[block]
        var cursor = MDXCursor(try MDXCompression.decode(read(at: info.position, count: info.compressed), expected: info.expanded))
        var entries: [Key] = []
        while cursor.remaining > 0 {
            if entries.count % 256 == 0 { try Task.checkCancellation() }
            let offset = try cursor.number(8)
            let word = try text(cursor.terminated(unit: unit))
            guard offset < totalRecords else { throw LocalDictionaryError.invalid("词条位置") }
            entries.append(Key(word: word, offset: offset))
        }
        // The block codec is bounded, and only small decoded blocks are cached.
        keyCache = info.expanded <= 128 * 1024 && entries.count <= 4096 ? (block, entries) : nil
        return entries
    }
    private func firstBlock(_ key: String) -> Int {
        var low = 0, high = keyBlocks.count
        while low < high {
            let mid = (low + high) / 2
            if less(keyBlocks[mid].last, key) { low = mid + 1 } else { high = mid }
        }
        return low
    }
    func words(_ query: String, prefix: Bool, limit: Int = 10) throws -> [String] {
        let key = normalized(query)
        guard !key.isEmpty else { return [] }
        var result: [String] = [], seen = Set<String>()
        var block = firstBlock(key)
        while block < keyBlocks.count {
            try Task.checkCancellation()
            let info = keyBlocks[block]
            if prefix {
                if less(key, info.first) && !info.first.hasPrefix(key) { break }
            } else if less(key, info.first) { break }
            for entry in try keys(block) {
                let candidate = normalized(entry.word)
                if prefix ? candidate.hasPrefix(key) : candidate == key {
                    if seen.insert(entry.word).inserted { result.append(entry.word) }
                    if result.count >= limit { return result }
                }
            }
            block += 1
        }
        return result
    }
    private func matches(_ query: String) throws -> [(Key, UInt64)] {
        let key = normalized(query)
        guard !key.isEmpty else { return [] }
        var block = firstBlock(key), result: [(Key, UInt64)] = []
        while block < keyBlocks.count, !less(key, keyBlocks[block].first) {
            let entries = try keys(block)
            for index in entries.indices where normalized(entries[index].word) == key {
                let entry = entries[index]
                var next = entries[(index + 1)...].first(where: { $0.offset > entry.offset })?.offset
                var following = block + 1
                while next == nil && following < keyBlocks.count {
                    next = try keys(following).first(where: { $0.offset > entry.offset })?.offset
                    following += 1
                }
                let end = next ?? totalRecords
                guard end > entry.offset, end - entry.offset <= UInt64(MDXCompression.limit) else {
                    throw LocalDictionaryError.invalid("词条长度异常")
                }
                result.append((entry, end))
                if result.count >= 32 { return result }
            }
            block += 1
        }
        return result
    }
    private func record(from start: UInt64, to end: UInt64) throws -> Data {
        var low = 0, high = recordBlocks.count
        while low < high {
            let mid = (low + high) / 2
            if recordBlocks[mid].end <= start { low = mid + 1 } else { high = mid }
        }
        var result = Data(), index = low
        while index < recordBlocks.count, recordBlocks[index].start < end {
            try Task.checkCancellation()
            let info = recordBlocks[index]
            let decoded: Data
            if let cache = recordCache, cache.0 == index { decoded = cache.1 }
            else {
                decoded = try MDXCompression.decode(read(at: info.position, count: info.compressed), expected: info.expanded)
                recordCache = decoded.count <= 1024 * 1024 ? (index, decoded) : nil
            }
            let begin = Int(max(start, info.start) - info.start)
            let finish = Int(min(end, info.end) - info.start)
            result.append(decoded[begin..<finish])
            index += 1
        }
        guard result.count == end - start else { throw LocalDictionaryError.invalid("词条跨块读取") }
        return result
    }
    #if ODICT_CHECKS
    func rawRecordsForChecks(_ word: String) throws -> [(word: String, offset: UInt64, content: String)] {
        try matches(word).map { key, end in
            (key.word, key.offset, try text(record(from: key.offset, to: end)))
        }
    }
    #endif

    func articles(_ word: String) throws -> [(String, String)] {
        var pending = [word], visited = Set<String>(), offsets = Set<UInt64>(), output: [(String, String)] = []
        var bytes = 0
        while let current = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(normalized(current)).inserted else { continue }
            guard visited.count <= 32 else { throw LocalDictionaryError.invalid("词条跳转过多") }
            for (key, end) in try matches(current) where offsets.insert(key.offset).inserted {
                let html = try text(record(from: key.offset, to: end))
                bytes += html.utf8.count
                guard bytes <= MDXCompression.limit else { throw LocalDictionaryError.invalid("词条内容过大") }
                if html.hasPrefix("@@@LINK=") {
                    pending.append(String(html.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines))
                } else if !html.isEmpty { output.append((key.word, html)) }
            }
        }
        return output
    }
    func resourceData(_ path: String) throws -> Data? {
        var path = path, visited = Set<String>()
        for _ in 0..<32 {
            guard visited.insert(normalized(path)).inserted else { throw LocalDictionaryError.invalid("资源循环跳转") }
            guard let (key, end) = try matches(path).first else { return nil }
            let data = try record(from: key.offset, to: end)
            let marker = Data([64, 0, 64, 0, 64, 0, 76, 0, 73, 0, 78, 0, 75, 0, 61, 0])
            if data.starts(with: marker), let value = String(data: data, encoding: .utf16LittleEndian) {
                path = String(value.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            } else { return data }
        }
        throw LocalDictionaryError.invalid("资源跳转过多")
    }
}
