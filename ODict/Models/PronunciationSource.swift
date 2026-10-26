import Foundation

struct PronunciationSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var template: String
    var enabled = true
    var colorHex = "3478F6"

    static let defaults = [
        PronunciationSource(name: "有道美音", template: "https://dict.youdao.com/dictvoice?audio={text}&type=2"),
        PronunciationSource(name: "有道英音", template: "https://dict.youdao.com/dictvoice?audio={text}&type=1", colorHex: "AF52DE")
    ]

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入来源名称。" }
        if !template.contains("{text}") { return "URL 模板需要包含 {text}。" }
        if resolvedURL(text: "ODict") == nil { return "请输入有效的 HTTPS URL；{text} 只能用于路径或参数值。" }
        if colorHex.count != 6 || UInt32(colorHex, radix: 16) == nil { return "请选择有效的图标颜色。" }
        return nil
    }

    func resolvedURL(text: String) -> URL? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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
