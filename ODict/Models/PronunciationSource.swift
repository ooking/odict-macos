import Foundation

struct PronunciationSource: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case remote, system
        var id: Self { self }
        var title: String { self == .system ? "系统语音" : "远程音频" }
    }

    enum VoiceGender: String, Codable, CaseIterable, Identifiable {
        case any, male, female
        var id: Self { self }
        var title: String {
            switch self {
            case .any: return "不限"
            case .male: return "男声"
            case .female: return "女声"
            }
        }
    }

    var id: UUID
    var name: String
    var template: String
    var enabled: Bool
    var colorHex: String
    var kind: Kind
    var systemVoiceIdentifier: String
    var systemVoiceGender: VoiceGender
    var systemLanguage: String
    var systemRate: Double

    init(id: UUID = UUID(), name: String, template: String = "", enabled: Bool = true,
         colorHex: String? = nil, kind: Kind = .remote,
         systemVoiceIdentifier: String = "", systemVoiceGender: VoiceGender = .any,
         systemLanguage: String = "", systemRate: Double = 0.85) {
        self.id = id
        self.name = name
        self.template = template
        self.enabled = enabled
        self.colorHex = colorHex ?? Self.randomColor(excluding: [])
        self.kind = kind
        self.systemVoiceIdentifier = systemVoiceIdentifier
        self.systemVoiceGender = systemVoiceGender
        self.systemLanguage = systemLanguage
        self.systemRate = systemRate
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, template, enabled, colorHex, kind
        case systemVoiceIdentifier, systemVoiceGender, systemLanguage, systemRate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        template = try values.decode(String.self, forKey: .template)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        colorHex = try values.decode(String.self, forKey: .colorHex)
        // Older saved sources are remote audio templates.
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .remote
        systemVoiceIdentifier = try values.decodeIfPresent(String.self, forKey: .systemVoiceIdentifier) ?? ""
        systemVoiceGender = try values.decodeIfPresent(VoiceGender.self, forKey: .systemVoiceGender) ?? .any
        systemLanguage = try values.decodeIfPresent(String.self, forKey: .systemLanguage) ?? ""
        systemRate = try values.decodeIfPresent(Double.self, forKey: .systemRate) ?? 0.85
    }

    static var defaults: [PronunciationSource] {
        var sources: [PronunciationSource] = []
        for (name, template) in [
            ("有道美音", "https://dict.youdao.com/dictvoice?audio={text}&type=2"),
            ("有道英音", "https://dict.youdao.com/dictvoice?audio={text}&type=1")
        ] {
            sources.append(PronunciationSource(name: name, template: template,
                colorHex: randomColor(excluding: Set(sources.map(\.colorHex)))))
        }
        sources.append(systemSource(excluding: Set(sources.map(\.colorHex))))
        return sources
    }

    static func systemSource(excluding colors: Set<String>) -> PronunciationSource {
        PronunciationSource(name: "系统语音", colorHex: randomColor(excluding: colors), kind: .system)
    }

    /// Bounded random selection with an exhaustive fallback. Restrict the random
    /// candidates to visible, reasonably saturated colors for small speaker icons.
    static func randomColor(excluding colors: Set<String>) -> String {
        let occupied = Set(colors.map { $0.uppercased() })
        for _ in 0..<64 {
            let channels = (0..<3).map { _ in Int.random(in: 40...215) }
            guard let low = channels.min(), let high = channels.max(), high >= 145,
                  high - low >= 65, channels.reduce(0, +) <= 510 else { continue }
            let candidate = String(format: "%02X%02X%02X", channels[0], channels[1], channels[2])
            if !occupied.contains(candidate) { return candidate }
        }
        // With at most 33 stored sources, at most 34 candidates are needed.
        for offset in 0...occupied.count {
            let candidate = String(format: "%06X", (0x3478F6 + offset) & 0xFFFFFF)
            if !occupied.contains(candidate) { return candidate }
        }
        return "3478F6"
    }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入来源名称。" }
        if kind == .system && (!systemRate.isFinite || !(0.5...1.5).contains(systemRate)) { return "语速应在 0.5–1.5 倍之间。" }
        if kind == .remote && !template.contains("{text}") { return "URL 模板需要包含 {text}。" }
        if kind == .remote && resolvedURL(text: "ODict") == nil { return "请输入有效的 HTTPS URL；{text} 只能用于路径或参数值。" }
        if colorHex.count != 6 || UInt32(colorHex, radix: 16) == nil { return "请选择有效的图标颜色。" }
        return nil
    }

    func resolvedURL(text: String) -> URL? {
        guard kind == .remote, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              template.contains("{text}") else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let probe = URLComponents(string: template.replacingOccurrences(of: "{text}", with: "ODICTPLACEHOLDER")),
              let host = probe.host, !host.lowercased().contains("odictplaceholder"),
              probe.scheme == "https", probe.user == nil, probe.password == nil, probe.fragment == nil,
              !host.isEmpty,
              probe.port.map({ (1...65535).contains($0) }) ?? true,
              let url = URL(string: template.replacingOccurrences(of: "{text}", with: encoded)) else { return nil }
        return url
    }
}
