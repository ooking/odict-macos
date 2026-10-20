import AVFoundation

@MainActor
final class PronunciationService {
    private var synthesizer: AVSpeechSynthesizer?
    func speak(_ word: String) {
        if synthesizer == nil { synthesizer = AVSpeechSynthesizer() }
        synthesizer?.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: word)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        synthesizer?.speak(utterance)
    }
    func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
    }
}
