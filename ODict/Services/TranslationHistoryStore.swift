import Foundation

/// One serial disk owner, compact grouped index, and one file per answer.
/// Opening a group never decodes its other answers or local dictionary resources.
actor TranslationHistoryStore {
    static let shared = TranslationHistoryStore()
    private struct Index: Codable { let version: Int; let groups: [TranslationHistoryGroup] }
    private let folder: URL
    private let preferences: UserDefaults
    private var groups: [TranslationHistoryGroup]?
    private let manager = FileManager.default
    private let recordLimit = 8 * 1024 * 1024
    private let diskLimit = 128 * 1024 * 1024

    init(folder: URL? = nil, preferences: UserDefaults = .standard) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.touchany.odict.mac/TranslationHistory", isDirectory: true)
        self.preferences = preferences
    }

    func summaries() throws -> [TranslationHistoryGroup] { try prepare(); return groups ?? [] }

    func record(source: String, method: TranslationMethod) throws -> TranslationHistoryRecord? {
        try prepare()
        guard let variant = groups?.first(where: { $0.source == source })?.variants.first(where: { $0.method == method }) else { return nil }
        let value = try JSONDecoder().decode(TranslationHistoryRecord.self, from: read(url(variant.id), limit: recordLimit))
        guard value.id == variant.id, value.source == source, value.method == method else { throw TranslationHistoryError.invalid }
        return value
    }

    func save(_ record: TranslationHistoryRecord) throws -> [TranslationHistoryGroup] {
        try prepare()
        if TranslationHistorySettings.capacity(in: preferences) == 0 { return try commit([]) }
        guard !record.source.isEmpty, record.source.count <= AIConfiguration.maximumInput,
              record.title.utf8.count <= 512 else { throw TranslationHistoryError.invalid }
        let data = try JSONEncoder().encode(record)
        guard data.count <= recordLimit else { throw TranslationHistoryError.tooLarge }
        var next = groups ?? []
        var group = next.first { $0.source == record.source } ?? TranslationHistoryGroup(
            id: UUID(), source: record.source, date: record.date, selectedMethod: record.method, variants: [])
        let preview: String
        switch record.payload {
        case .online(let entry): preview = entry.translation ?? entry.definition ?? ""
        case .system(_, let text): preview = text
        case .mdx(_, _, let summary): preview = summary.isEmpty ? "本地词条 · 打开时读取词典" : summary
        case .ai(let markdown, _, let partial): preview = (partial ? "未完成 · " : "") + String(markdown.prefix(160))
        }
        group.variants.removeAll { $0.method == record.method }
        group.variants.append(TranslationHistoryVariant(id: record.id, method: record.method, title: record.title,
            preview: String(preview.prefix(160)).split(whereSeparator: \.isWhitespace).joined(separator: " "), bytes: data.count))
        // Imported MDX identities may change over time. Bound variants per source too.
        if group.variants.count > 36 { group.variants.removeFirst(group.variants.count - 36) }
        while group.variants.count > 1 && group.variants.reduce(0, { $0 + $1.bytes }) > 32 * 1024 * 1024 {
            group.variants.removeFirst()
        }
        group.selectedMethod = record.method; group.date = record.date
        next.removeAll { $0.source == record.source }; next.insert(group, at: 0)
        try write(data, to: url(record.id))
        return try commit(next)
    }

    func select(source: String, method: TranslationMethod) throws -> [TranslationHistoryGroup] {
        try prepare()
        var next = groups ?? []
        guard let index = next.firstIndex(where: { $0.source == source }) else { return next }
        next[index].selectedMethod = method; next[index].date = Date()
        return try commit(next)
    }
    func trim() throws -> [TranslationHistoryGroup] { try prepare(); return try commit(groups ?? []) }
    func clear() throws -> [TranslationHistoryGroup] {
        // Clearing must remain available even if the index itself is damaged.
        try ensureFolder()
        return try commit([])
    }

    private var indexURL: URL { folder.appendingPathComponent("index.json") }
    private func url(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }
    private func prepare() throws {
        guard groups == nil else { return }
        try ensureFolder()
        var saved: [TranslationHistoryGroup] = []
        if manager.fileExists(atPath: indexURL.path) {
            let index = try JSONDecoder().decode(Index.self, from: read(indexURL, limit: 8 * 1024 * 1024))
            guard index.version == 1, index.groups.count <= 100,
                  index.groups.allSatisfy({ !$0.source.isEmpty && $0.source.count <= 4000 && $0.variants.count <= 36
                      && $0.variants.allSatisfy { $0.bytes >= 0 && $0.bytes <= recordLimit && $0.preview.count <= 160 && $0.title.utf8.count <= 512 } })
            else { throw TranslationHistoryError.invalid }
            saved = index.groups
        }
        _ = try commit(saved)
    }
    private func ensureFolder() throws {
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw TranslationHistoryError.invalid }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }
    private func commit(_ values: [TranslationHistoryGroup]) throws -> [TranslationHistoryGroup] {
        var next = Array(values.sorted { $0.date > $1.date }.prefix(TranslationHistorySettings.capacity(in: preferences)))
        var bytes = next.reduce(0) { $0 + $1.variants.reduce(0) { $0 + $1.bytes } }
        while bytes > diskLimit, let removed = next.popLast() {
            bytes -= removed.variants.reduce(0) { $0 + $1.bytes }
        }
        let indexData = try JSONEncoder().encode(Index(version: 1, groups: next))
        guard indexData.count <= 8 * 1024 * 1024 else { throw TranslationHistoryError.tooLarge }
        try write(indexData, to: indexURL)
        groups = next
        // Commit first: interrupted deletion leaves harmless orphans, removed at next load/write.
        let keep = Set(next.flatMap { $0.variants.map(\.id) })
        guard let files = manager.enumerator(at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { throw TranslationHistoryError.invalid }
        var count = 0
        while let file = files.nextObject() as? URL {
            count += 1
            guard count <= 4096 else { throw TranslationHistoryError.tooLarge }
            if file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !keep.contains(id) {
                try manager.removeItem(at: file)
            }
        }
        return next
    }
    private func read(_ file: URL, limit: Int) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= limit else { throw TranslationHistoryError.invalid }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw TranslationHistoryError.tooLarge }
        return data
    }
    private func write(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
