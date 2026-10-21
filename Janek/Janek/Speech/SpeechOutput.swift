import AVFoundation

/// Synteza mowy po polsku (AVSpeechSynthesizer) z oczekiwaniem na koniec wypowiedzi.
@MainActor
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Polskie głosy dostępne na urządzeniu – najlepsze (Premium/Enhanced) na początku.
    static var polishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "pl-PL" }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    static func voice(identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) { return voice }
        return polishVoices.first ?? AVSpeechSynthesisVoice(language: "pl-PL")
    }

    func speak(_ text: String, settings: AppSettings) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        try? await AudioSessionController.activate(ducking: true)
        let utterance = AVSpeechUtterance(string: Self.cleanForSpeech(trimmed))
        utterance.voice = Self.voice(identifier: settings.voiceIdentifier)
        utterance.rate = settings.speechRate
        utterance.postUtteranceDelay = 0.05
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
        try? await AudioSessionController.activate(ducking: false)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        resume()
    }

    private func resume() {
        continuation?.resume()
        continuation = nil
    }

    /// Usuwa resztki formatowania, których syntezator nie powinien czytać.
    static func cleanForSpeech(_ text: String) -> String {
        var result = text
        for token in ["**", "__", "`", "#", "* ", "- "] { result = result.replacingOccurrences(of: token, with: " ") }
        result = result.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }
}

/// Krótkie dźwięki sygnalizujące (początek/koniec słuchania).
@MainActor
enum Earcons {
    private static var players: [String: AVAudioPlayer] = [:]

    static func play(_ name: String) {
        guard AppSettings.shared.playEarcons else { return }
        if players[name] == nil, let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            players[name] = try? AVAudioPlayer(contentsOf: url)
        }
        players[name]?.currentTime = 0
        players[name]?.play()
    }

    static func listening() { play("janek_listen") }
    static func done() { play("janek_done") }
}
