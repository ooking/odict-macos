import Foundation

/// Serial disk owner. Only the bounded summary index stays in memory; complete
/// answers are decoded one at a time, when selected or recovered after a crash.
actor AIHistoryStore {
    static let shared = AIHistoryStore()
    private struct Index: Codable {
        let version: Int
        let records: [AIHistorySummary]
    }
    private let folder: URL
    private let preferences: UserDefaults
    private let fileManager = FileManager.default
    private let recordByteLimit = 8 * 1024 * 1024
    private var index: [AIHistorySummary]?
    private var obsolete: Set<UUID> = []
    private var recoveryNotice: String?

    init(folder: URL? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.touchany.odict.mac/AIHistory", isDirectory: true)
    }

    func summaries() throws -> AIHistorySnapshot {
        try prepare()
        return AIHistorySnapshot(records: index ?? [], notice: recoveryNotice)
    }

    func record(_ id: UUID) throws -> AIHistoryRecord {
        try prepare()
        guard index?.contains(where: { $0.id == id }) == true else { throw AIHistoryError.invalidRecord }
        return try readRecord(id)
    }

    func save(_ record: AIHistoryRecord) throws -> AIHistorySnapshot {
        try prepare()
        try validate(record)
        let data = try JSONEncoder().encode(record)
        guard data.count <= recordByteLimit else { throw AIHistoryError.tooLarge }
        // Write the complete answer first. An orphaned answer is recovered by
        // prepare() if the app exits before committing its index entry.
        try write(data, to: recordURL(record.id))
        let next = [record.summary] + (index ?? []).filter { $0.id != record.id }
        do { return try commit(next) }
        catch { index = nil; throw error }
    }

    func trim() throws -> AIHistorySnapshot {
        try prepare()
        return try commit(index ?? [])
    }

    func clear() throws -> AIHistorySnapshot {
        try ensureFolder()
        // Also remove orphaned/corrupt record files on an explicit clear.
        // Stop on failure and retain the old index so a retry remains possible.
        for id in try recordIDs() { try fileManager.removeItem(at: recordURL(id)) }
        try write(try JSONEncoder().encode(Index(version: 1, records: [])), to: indexURL)
        index = []
        obsolete = []
        recoveryNotice = nil
        return AIHistorySnapshot(records: [], notice: nil)
    }

    private var indexURL: URL { folder.appendingPathComponent("index.json") }
    private func recordURL(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    private func ensureFolder() throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AIHistoryError.invalidRecord }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    private func prepare() throws {
        guard index == nil else { return }
        try ensureFolder()
        var summaries: [AIHistorySummary] = []
        if fileManager.fileExists(atPath: indexURL.path),
           let data = try? read(indexURL, limit: 512 * 1024),
           let saved = try? JSONDecoder().decode(Index.self, from: data) {
            guard saved.version == 1 else { throw AIHistoryError.invalidRecord }
            summaries = saved.records.filter {
                $0.sourcePreview.count <= 160 && $0.answerPreview.count <= 160 && $0.model.utf8.count <= 2048
            }
        }
        let ids = try recordIDs()
        let existing = Set(ids)
        summaries.removeAll { !existing.contains($0.id) }
        var seen = Set<UUID>()
        summaries = summaries.filter { seen.insert($0.id).inserted }
        // Normally only a single interrupted commit needs recovery. A damaged
        // index is rebuilt sequentially, never loading all answers together.
        for id in ids where !seen.contains(id) {
            do {
                let record = try readRecord(id)
                summaries.append(record.summary)
                seen.insert(id)
            } catch {
                // Preserve damaged files for recovery; a single bad record must
                // not prevent saving or opening the other valid answers.
                recoveryNotice = "部分历史文件无法读取，原文件已保留，其余记录仍可使用。"
            }
        }
        _ = try commit(summaries)
    }

    private func recordIDs() throws -> [UUID] {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: { _, error in
                enumerationError = error; return false
            }) else { throw AIHistoryError.invalidRecord }
        var ids: [UUID] = []
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            count += 1
            guard count <= 256 else { throw AIHistoryError.tooManyFiles }
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            ids.append(id)
        }
        if let enumerationError { throw enumerationError }
        return ids
    }

    private func readRecord(_ id: UUID) throws -> AIHistoryRecord {
        let value = try JSONDecoder().decode(AIHistoryRecord.self, from: read(recordURL(id), limit: recordByteLimit))
        guard value.id == id else { throw AIHistoryError.invalidRecord }
        try validate(value)
        return value
    }

    private func validate(_ record: AIHistoryRecord) throws {
        guard !record.source.isEmpty, !record.markdown.isEmpty,
              record.source.utf8.count <= 1024 * 1024, record.markdown.utf8.count <= 4 * 1024 * 1024,
              record.model.utf8.count <= 2048 else { throw AIHistoryError.invalidRecord }
    }

    private func read(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= limit else { throw AIHistoryError.tooLarge }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw AIHistoryError.tooLarge }
        return data
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func commit(_ values: [AIHistorySummary]) throws -> AIHistorySnapshot {
        let sorted = values.sorted { $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date }
        let keep = Array(sorted.prefix(AIHistorySettings.capacity(in: preferences)))
        try write(try JSONEncoder().encode(Index(version: 1, records: keep)), to: indexURL)
        index = keep
        obsolete.subtract(keep.map(\.id))
        obsolete.formUnion(sorted.dropFirst(keep.count).map(\.id))
        for id in Array(obsolete) {
            if fileManager.fileExists(atPath: recordURL(id).path) {
                try fileManager.removeItem(at: recordURL(id))
            }
            obsolete.remove(id)
        }
        return AIHistorySnapshot(records: keep, notice: recoveryNotice)
    }
}
