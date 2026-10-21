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

    static func decide(_ command: String) async throws -> CommandFields? {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: LocalCommandRouter.instructions())
        let response = try await session.respond(
            to: command,
            generating: GeneratedCommand.self,
            options: GenerationOptions(samplingMode: .greedy, temperature: nil, maximumResponseTokens: 300)
        )
        return response.content.fields
        #else
        return nil
        #endif
    }
}
