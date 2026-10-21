import AVFoundation
import Foundation
import Observation

/// Czułość wykrywania słowa „Hej Janek” (maksymalna odległość edycyjna dla imienia).
enum WakeSensitivity: Int, CaseIterable, Identifiable, Sendable {
    case strict = 0, normal = 1, loose = 2
    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .strict: "Dokładna"
        case .normal: "Normalna"
        case .loose: "Wysoka (więcej fałszywych wybudzeń)"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    var model: ClaudeModel { didSet { defaults.set(model.rawValue, forKey: "model") } }
    var effort: ClaudeEffort { didSet { defaults.set(effort.rawValue, forKey: "effort") } }
    var webSearchEnabled: Bool { didSet { defaults.set(webSearchEnabled, forKey: "webSearch") } }
    var wakeWordEnabled: Bool { didSet { defaults.set(wakeWordEnabled, forKey: "wakeWord") } }
    var wakeSensitivity: WakeSensitivity { didSet { defaults.set(wakeSensitivity.rawValue, forKey: "wakeSensitivity") } }
    var listenInBackground: Bool { didSet { defaults.set(listenInBackground, forKey: "listenInBackground") } }
    var onDeviceRecognition: Bool { didSet { defaults.set(onDeviceRecognition, forKey: "onDevice") } }
    var voiceIdentifier: String? { didSet { defaults.set(voiceIdentifier, forKey: "voice") } }
    var speechRate: Float { didSet { defaults.set(speechRate, forKey: "speechRate") } }
    var alarmSound: AlarmSound { didSet { defaults.set(alarmSound.rawValue, forKey: "alarmSound") } }
    var playEarcons: Bool { didSet { defaults.set(playEarcons, forKey: "earcons") } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "onboarded") } }
    var aiMode: AIMode { didSet { defaults.set(aiMode.rawValue, forKey: "aiMode") } }
    var localEngine: LocalEngineChoice { didSet { defaults.set(localEngine.rawValue, forKey: "localEngine") } }
    var localModel: LocalModelPreset { didSet { defaults.set(localModel.rawValue, forKey: "localModel") } }

    private init() {
        defaults.register(defaults: [
            "model": ClaudeModel.opus.rawValue, "effort": ClaudeEffort.low.rawValue, "webSearch": true,
            "wakeWord": true, "wakeSensitivity": WakeSensitivity.normal.rawValue, "listenInBackground": true,
            "onDevice": true, "speechRate": AVSpeechUtteranceDefaultSpeechRate, "alarmSound": AlarmSound.classic.rawValue,
            "earcons": true, "onboarded": false, "aiMode": AIMode.hybrid.rawValue,
            "localEngine": LocalEngineChoice.automatic.rawValue, "localModel": LocalModelPreset.gemma4_e2b.rawValue,
        ])
        model = ClaudeModel(rawValue: defaults.string(forKey: "model") ?? "") ?? .opus
        effort = ClaudeEffort(rawValue: defaults.string(forKey: "effort") ?? "") ?? .low
        webSearchEnabled = defaults.bool(forKey: "webSearch")
        wakeWordEnabled = defaults.bool(forKey: "wakeWord")
        wakeSensitivity = WakeSensitivity(rawValue: defaults.integer(forKey: "wakeSensitivity")) ?? .normal
        listenInBackground = defaults.bool(forKey: "listenInBackground")
        onDeviceRecognition = defaults.bool(forKey: "onDevice")
        voiceIdentifier = defaults.string(forKey: "voice")
        speechRate = defaults.float(forKey: "speechRate")
        alarmSound = AlarmSound(rawValue: defaults.string(forKey: "alarmSound") ?? "") ?? .classic
        playEarcons = defaults.bool(forKey: "earcons")
        hasCompletedOnboarding = defaults.bool(forKey: "onboarded")
        aiMode = AIMode(rawValue: defaults.string(forKey: "aiMode") ?? "") ?? .hybrid
        localEngine = LocalEngineChoice(rawValue: defaults.string(forKey: "localEngine") ?? "") ?? .automatic
        localModel = LocalModelPreset(rawValue: defaults.string(forKey: "localModel") ?? "") ?? .gemma4_e2b
    }
}
