import Foundation

struct LocalDictionaryConfiguration: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    let mdxPath: String
    var resources: [String]
    var enabled: Bool
    // Optional storage preserves decoding of existing v1 configurations.
    private var overrideStyleEnabled: Bool? = nil
    var usesOverrideStyle: Bool {
        get { overrideStyleEnabled ?? true }
        set { overrideStyleEnabled = newValue }
    }
    init(id: UUID, name: String, mdxPath: String, resources: [String], enabled: Bool, usesOverrideStyle: Bool = true) {
        self.id = id; self.name = name; self.mdxPath = mdxPath
        self.resources = resources; self.enabled = enabled
        self.overrideStyleEnabled = usesOverrideStyle
    }
    var folder: URL { URL(fileURLWithPath: mdxPath).deletingLastPathComponent() }
}

enum DictionaryMode: String, CaseIterable, Identifiable {
    case localFirst, onlineOnly
    var id: String { rawValue }
    var title: String { self == .localFirst ? "本地优先，在线兜底" : "仅使用在线词典" }
}

struct LocalDictionaryStore {
    static let configurationKey = "localDictionaries.v1"
    static let modeKey = "dictionaryMode.v1"
    static let changed = Notification.Name("ODictDictionarySourcesChanged")
    static let maximumCount = 32
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var mode: DictionaryMode {
        DictionaryMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .localFirst
    }
    func load() -> [LocalDictionaryConfiguration] {
        guard let data = defaults.data(forKey: Self.configurationKey),
              let items = try? JSONDecoder().decode([LocalDictionaryConfiguration].self, from: data) else { return [] }
        return Array(items.prefix(Self.maximumCount))
    }
    func save(_ items: [LocalDictionaryConfiguration], mode: DictionaryMode) throws {
        guard items.count <= Self.maximumCount else { throw LocalDictionaryError.invalid("最多添加 32 本词典") }
        defaults.set(try JSONEncoder().encode(items), forKey: Self.configurationKey)
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

struct LocalArticle: Identifiable, Sendable {
    let id = UUID()
    let dictionary: LocalDictionaryConfiguration
    /// The selected/query word is the result identity, including after redirects.
    let word: String
    /// Terminal record keys are separate metadata; HTML remains untouched.
    let headwords: [String]
    let html: String
    var summary: String? = nil

    var correspondingHeadwords: [String] {
        headwords.filter { $0.caseInsensitiveCompare(word) != .orderedSame }
    }
}

/// Discovery only associates a uniquely selected MDX with resources in its folder.
/// A multi-MDX folder is ambiguous: resources must be assigned explicitly in settings.
enum LocalDictionaryDiscovery {
    static func discover(_ selected: URL) throws -> [LocalDictionaryConfiguration] {
        let directory = (try selected.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        let folder = directory ? selected : selected.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        let allMDX = files.filter { $0.pathExtension.lowercased() == "mdx" }.sorted { $0.path < $1.path }
        let chosen = directory ? allMDX : [selected]
        guard chosen.count <= LocalDictionaryStore.maximumCount else { throw LocalDictionaryError.invalid("单次最多添加 32 本词典") }
        guard !chosen.isEmpty, chosen.allSatisfy({ $0.pathExtension.lowercased() == "mdx" }) else {
            throw LocalDictionaryError.invalid("请选择 MDX 文件或包含 MDX 的文件夹")
        }
        return try chosen.map { mdx in
            let basename = mdx.deletingPathExtension().lastPathComponent.lowercased()
            let mdds = files.filter { file in
                guard file.pathExtension.lowercased() == "mdd" else { return false }
                if allMDX.count == 1 { return true }
                let name = file.deletingPathExtension().lastPathComponent.lowercased()
                return name == basename || (name.hasPrefix(basename + ".") && Int(name.dropFirst(basename.count + 1)) != nil)
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            guard mdds.count <= 128 else { throw LocalDictionaryError.invalid("资源包数量超出上限") }
            // Header-only discovery does not initialize or validate compressed blocks.
            let file = try FileHandle(forReadingFrom: mdx)
            defer { try? file.close() }
            var prefix = MDXCursor(try file.read(upToCount: 4) ?? Data())
            let length = try prefix.number(4)
            guard length > 0, length <= 1024 * 1024 else { throw LocalDictionaryError.invalid("MDX 文件头大小") }
            let header = try MDXHeader.read(file.read(upToCount: Int(length)) ?? Data())
            guard header["GeneratedByEngineVersion"] == "2.0" else { throw LocalDictionaryError.unsupported("当前支持 MDX 2.0") }
            return LocalDictionaryConfiguration(id: UUID(), name: header["Title"] ?? basename,
                mdxPath: mdx.standardizedFileURL.path, resources: mdds.map { $0.standardizedFileURL.path }, enabled: true)
        }
    }
}

/// User-editable presentation policy lives beside each dictionary, never in a
/// dictionary-specific Swift HTML adapter. Existing overrides are never overwritten.
enum LocalDictionaryOverrides {
    static let cssName = "odict-overrides.css"
    static let jsName = "odict-overrides.js"
    static func create(in folder: URL) throws {
        let url = folder.appendingPathComponent(cssName)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data(defaultCSS.utf8).write(to: url, options: [.withoutOverwriting])
        }
    }
    // Upgrade only our exact original template. Any user-authored changes win.
    static func upgradedCSS(_ data: Data) -> Data {
        data == Data(legacyCSS.utf8) ? Data(defaultCSS.utf8) : data
    }
    private static let legacyCSS = """
    /* ODict local dictionary overrides. Edit freely; ODict never overwrites this file.
       Optional odict-overrides.js in this folder runs after the article loads.
       Keep dictionary-specific layout rules here. Original MDX/MDD files stay unchanged. */
    :root { color-scheme: light dark; }
    html { background: transparent !important; }
    body { margin: 14px; font-size: 15px; overflow-wrap: anywhere; }
    img, video, table { max-width: 100%; }
    @media (prefers-color-scheme: dark) {
      body { background-color: #202124 !important; color: #e6e6e6; }
      a { color: #93baff; }
    }
    """
    static let defaultCSS = """
    /* ODict local dictionary overrides. Edit freely; user changes are preserved.
       Optional odict-overrides.js runs after the article loads.
       Dictionary-specific layout and colors belong in this file, not in the app.
       Configure reading fonts and sizes in Settings > Appearance; do not set
       font-family, font-size or font shorthand here. */
    :root {
      color-scheme: light dark;
      --odict-text: CanvasText;
      --odict-secondary: rgba(35, 35, 40, .72);
      --odict-accent: #155a98;
      --odict-example: #176861;
      --odict-grammar: #2b6a39;
      --odict-emphasis: #a13737;
      --odict-rule: rgba(30, 30, 35, .2);
      --odict-section: rgba(30, 30, 35, .045);
    }
    html, body {
      background: transparent !important;
      color: var(--odict-text) !important;
    }
    body { margin: 14px; overflow-wrap: anywhere; }
    img, video, table { max-width: 100%; }
    @media (prefers-color-scheme: dark) {
      :root {
        --odict-secondary: rgba(235, 235, 245, .76);
        --odict-accent: #a6ceff;
        --odict-example: #99d9d0;
        --odict-grammar: #a7d4a2;
        --odict-emphasis: #ffb5ad;
        --odict-rule: rgba(235, 235, 245, .24);
        --odict-section: rgba(235, 235, 245, .055);
      }
    }
    """
}
