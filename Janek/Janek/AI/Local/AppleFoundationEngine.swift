import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Model Apple Intelligence na urządzeniu (framework Foundation Models).
/// Działa tylko, gdy Apple Intelligence jest włączone i model obsługuje język polecenia.
@MainActor
enum AppleFoundationEngine {
    enum Status: Equatable {
        case ready
        case polishNotSupported
        case notEnabled
        case deviceNotEligible
        case downloading
        case unavailable

        var description: String {
            switch self {
            case .ready: "Gotowy"
            case .polishNotSupported: "Model Apple nie obsługuje jeszcze polskiego"
            case .notEnabled: "Włącz Apple Intelligence w Ustawieniach iOS"
            case .deviceNotEligible: "To urządzenie nie obsługuje Apple Intelligence"
            case .downloading: "Model Apple jest pobierany przez system"
            case .unavailable: "Niedostępny"
            }
        }
    }

    static var status: Status {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(Locale(identifier: "pl_PL")) ? .ready : .polishNotSupported
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.modelNotReady):
            return .downloading
        case .unavailable(.appleIntelligenceNotEnabled):
            return .notEnabled
        case .unavailable:
            return .unavailable
        }
        #else
        return .unavailable
        #endif
    }

    /// Model dostępny (choćby bez oficjalnej obsługi polskiego – wtedy próbujemy, a błąd oznacza przekazanie do Claude).
    static var isAvailable: Bool {
        status == .ready || status == .polishNotSupported
    }

    static func decide(_ command: String) async throws -> LocalDecision? {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: LocalCommandRouter.instructions())
        let response = try await session.respond(
            to: command,
            generating: GeneratedDecision.self,
            options: GenerationOptions(sampling: .greedy, temperature: nil, maximumResponseTokens: 300)
        )
        return LocalCommandRouter.parse(tool: response.content.tool, argumentsJSON: response.content.argumentsJSON)
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
/// Struktura generowana przez model Apple – nazwa narzędzia jest ograniczona do znanych wartości.
@Generable
struct GeneratedDecision {
    @Guide(description: "Nazwa narzędzia albo \"claude\", gdy polecenie trzeba przekazać dalej", .anyOf([
        "timer_start", "alarm_set", "alarm_cancel", "music_control", "music_play", "phone_call", "message_send",
        "note_create", "note_append", "note_read", "reminder_create", "calendar_create_event", "maps_navigate",
        "contact_find", "health_read", "workout", "app_open", "shortcut_run", "claude",
    ]))
    var tool: String

    @Guide(description: "Argumenty narzędzia jako obiekt JSON, np. {\"seconds\": 300}; dla \"claude\" pusty obiekt {}")
    var argumentsJSON: String
}
#endif
