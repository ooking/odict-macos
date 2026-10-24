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
        #if DEBUG
        LocalDictionaryDebug.trace("lookup.begin", "word=\(String(reflecting: word)) dictionary=\(String(reflecting: dictionary.name))")
        #endif
        try Task.checkCancellation()
        let entries = try reader(dictionary.mdxPath).articles(word)
        guard !entries.isEmpty else {
            #if DEBUG
            LocalDictionaryDebug.trace("lookup.miss", "word=\(String(reflecting: word)) dictionary=\(String(reflecting: dictionary.name))")
            #endif
            return nil
        }
        var seen = Set<String>()
        let headwords = entries.map(\.0).filter { seen.insert($0).inserted }
        let html = entries.map(\.1).joined(separator: "\n")
        let article = LocalArticle(dictionary: dictionary, word: word, headwords: headwords,
                            html: html, summary: LocalArticleSummary.extract(from: html))
        #if DEBUG
        LocalDictionaryDebug.trace("lookup.hit", articleID: article.id, "records=\(entries.count) headwords=\(headwords)")
        LocalDictionaryDebug.html(html, stage: "raw", article: article)
        #endif
        return article
    }
    func words(_ query: String, in dictionary: LocalDictionaryConfiguration, exact: Bool) throws -> [Suggestion] {
        try reader(dictionary.mdxPath).words(query, prefix: !exact, limit: exact ? 1 : 10).map {
            Suggestion(word: $0, phonetic: nil, translationPreview: nil, translation: nil)
        }
    }
    /// Build on this serial background owner, never scan large HTML on the UI actor.
    func document(_ article: LocalArticle) throws -> Data {
        #if DEBUG
        let memory = MemoryPhaseDiagnostics.Span("article.document")
        defer { memory.mark("finished") }
        #endif
        try Task.checkCancellation()
        let css = try resource("/odict-overrides.css", in: article.dictionary)
        try Task.checkCancellation()
        let document = try LocalArticleDocument.make(article: article,
                    overridesCSS: String(decoding: css, as: UTF8.self))
        #if DEBUG
        LocalDictionaryDebug.trace("document.built", articleID: article.id, "htmlBytes=\(document.utf8.count) inlineCSSBytes=\(css.count)")
        LocalDictionaryDebug.html(document, stage: "document", article: article)
        #endif
        return Data(document.utf8)
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
            #if DEBUG
            LocalDictionaryDebug.trace("resource.resolved", "path=\(String(reflecting: normalized)) source=disk bytes=\(data.count)")
            #endif
            return normalized == LocalDictionaryOverrides.cssName ? LocalDictionaryOverrides.upgradedCSS(data) : data
        }
        if normalized == LocalDictionaryOverrides.jsName {
            #if DEBUG
            LocalDictionaryDebug.trace("resource.resolved", "path=\(normalized) source=optional-empty")
            #endif
            return Data()
        }
        if normalized == LocalDictionaryOverrides.cssName {
            #if DEBUG
            LocalDictionaryDebug.trace("resource.resolved", "path=\(normalized) source=builtin")
            #endif
            return Data(LocalDictionaryOverrides.defaultCSS.utf8)
        }
        var failure: Error?
        for resource in dictionary.resources {
            try Task.checkCancellation()
            do {
                if let data = try reader(resource, resource: true).resourceData(normalized) {
                    #if DEBUG
                    LocalDictionaryDebug.trace("resource.resolved", "path=\(String(reflecting: normalized)) source=mdd bytes=\(data.count)")
                    #endif
                    return data
                }
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
