import Foundation

/// Serial background owner of file handles and bounded caches. Small LRU keeps
/// frequently used MDX/MDD directories without retaining all configured dictionaries.
actor LocalDictionaryLibrary {
    static let shared = LocalDictionaryLibrary()
    private var readers: [(String, MDXReader)] = []
    private func reader(_ path: String, resource: Bool = false) throws -> MDXReader {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        let fingerprint = "\(path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(String(describing: values.fileResourceIdentifier))"
        if let index = readers.firstIndex(where: { $0.0 == fingerprint }) {
            let hit = readers.remove(at: index); readers.append(hit); return hit.1
        }
        readers.removeAll { $0.1.url == url }
        let value = try MDXReader(url: url)
        let budget = 12 * 1024 * 1024
        while !readers.isEmpty && (readers.count >= 4 || readers.reduce(0, { $0 + $1.1.residentBudget }) + value.residentBudget > budget) {
            readers.removeFirst()
        }
        if value.residentBudget <= budget { readers.append((fingerprint, value)) }
        return value
    }
    func article(_ word: String, in dictionary: LocalDictionaryConfiguration) throws -> LocalArticle? {
        try Task.checkCancellation()
        let entries = try reader(dictionary.mdxPath).articles(word)
        guard !entries.isEmpty else { return nil }
        var seen = Set<String>()
        let headwords = entries.map(\.0).filter { seen.insert($0).inserted }
        let html = entries.map(\.1).joined(separator: "\n")
        return LocalArticle(dictionary: dictionary, word: word, headwords: headwords,
                            html: html, summary: LocalArticleSummary.extract(from: html))
    }
    func words(_ query: String, in dictionary: LocalDictionaryConfiguration, exact: Bool) throws -> [Suggestion] {
        try reader(dictionary.mdxPath).words(query, prefix: !exact, limit: exact ? 1 : 10).map {
            Suggestion(word: $0, phonetic: nil, translationPreview: nil, translation: nil)
        }
    }
    func resource(_ path: String, in dictionary: LocalDictionaryConfiguration) throws -> Data {
        try Task.checkCancellation()
        let folder = dictionary.folder.resolvingSymlinksInPath().standardizedFileURL
        let normalized = path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let file = folder.appendingPathComponent(normalized).resolvingSymlinksInPath().standardizedFileURL
        // Both external resources and symlinks are constrained to the selected folder.
        guard file.path.hasPrefix(folder.path + "/"), !normalized.split(separator: "/").contains("..") else {
            throw LocalDictionaryError.missingResource
        }
        if FileManager.default.fileExists(atPath: file.path) {
            let properties = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard properties.isRegularFile == true, (properties.fileSize ?? Int.max) <= MDXCompression.limit else {
                throw LocalDictionaryError.invalid("资源文件过大或不是普通文件")
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: MDXCompression.limit) ?? Data()
            return normalized == LocalDictionaryOverrides.cssName ? LocalDictionaryOverrides.upgradedCSS(data) : data
        }
        if normalized == LocalDictionaryOverrides.jsName { return Data() }
        if normalized == LocalDictionaryOverrides.cssName { return Data(LocalDictionaryOverrides.defaultCSS.utf8) }
        var failure: Error?
        for resource in dictionary.resources {
            try Task.checkCancellation()
            do {
                if let data = try reader(resource, resource: true).resourceData(normalized) { return data }
            } catch is CancellationError { throw CancellationError() }
            catch { failure = error }
        }
        if let failure { throw failure }
        throw LocalDictionaryError.missingResource
    }
    func release() { readers.removeAll() }
    #if ODICT_CHECKS
    func readerCountForChecks() -> Int { readers.count }
    #endif
}
