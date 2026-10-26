import AVFoundation
import NaturalLanguage

/// A settings-only snapshot of installed voices. No speech engine or ongoing
/// voice observer is retained; refresh explicitly after downloading more voices.
struct SystemSpeechVoice: Identifiable {
    let id: String
    let name: String
    let language: String
    let gender: PronunciationSource.VoiceGender

    var title: String {
        let genderName = gender == .any ? "性别未标注" : gender.title
        return "\(name) · \(Self.languageTitle(language)) · \(genderName)"
    }

    static func languageTitle(_ language: String) -> String {
        Locale(identifier: "zh-Hans").localizedString(forIdentifier: language) ?? language
    }

    static func installed() -> [SystemSpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices().map {
            SystemSpeechVoice(id: $0.identifier, name: $0.name, language: $0.language, gender: gender(of: $0))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func matches(_ source: PronunciationSource) -> Bool {
        (source.systemLanguage.isEmpty || language == source.systemLanguage)
            && (source.systemVoiceGender == .any || gender == source.systemVoiceGender)
    }

    static func resolve(source: PronunciationSource, text: String) throws -> AVSpeechSynthesisVoice {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if !source.systemVoiceIdentifier.isEmpty {
            guard let selected = voices.first(where: { $0.identifier == source.systemVoiceIdentifier }) else {
                throw VoiceError.missingSelection
            }
            return selected
        }
        let detected = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
        let preferred = source.systemLanguage.isEmpty
            ? (["en": "en-US", "zh-Hans": "zh-CN", "zh-Hant": "zh-TW"][detected] ?? detected)
            : source.systemLanguage
        let baseLanguage = detected.split(separator: "-").first.map(String.init) ?? detected
        let candidates = voices.filter { voice in
            let languageMatches = voice.language == preferred || (source.systemLanguage.isEmpty
                && (voice.language == baseLanguage || voice.language.hasPrefix(baseLanguage + "-")))
            return languageMatches && (source.systemVoiceGender == .any || gender(of: voice) == source.systemVoiceGender)
        }
        guard let selected = candidates.first(where: { $0.language == preferred }) ?? candidates.first else {
            throw VoiceError.noMatch
        }
        return selected
    }

    private static func gender(of voice: AVSpeechSynthesisVoice) -> PronunciationSource.VoiceGender {
        switch voice.gender {
        case .male: return .male
        case .female: return .female
        default: return .any
        }
    }

    private enum VoiceError: LocalizedError {
        case missingSelection, noMatch
        var errorDescription: String? {
            switch self {
            case .missingSelection: return "所选语音已不可用，请重新选择角色，或在系统设置的「辅助功能」中下载该语音。"
            case .noMatch: return "未找到符合语言和性别设置的语音，请调整选项，或在系统设置的「辅助功能」中下载语音。"
            }
        }
    }
}
