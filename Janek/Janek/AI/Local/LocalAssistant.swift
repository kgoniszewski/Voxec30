import Foundation

/// Tryb pracy „mózgu” asystenta.
enum AIMode: String, CaseIterable, Identifiable, Sendable {
    case cloud, hybrid, local
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .cloud: "Tylko Claude"
        case .hybrid: "Hybrydowy (zalecany)"
        case .local: "Tylko na telefonie"
        }
    }
    var details: String {
        switch self {
        case .cloud: "Każde polecenie rozumie Claude. Najlepsza jakość, wymaga klucza API i internetu."
        case .hybrid: "Proste polecenia (minutnik, muzyka, telefon, notatki…) obsługuje model na telefonie – za darmo i offline. Resztę przejmuje Claude."
        case .local: "Bez klucza API i bez internetu. Tylko proste polecenia; brak odpowiedzi na pytania ogólne."
        }
    }
}

/// Który model lokalny wykorzystać.
enum LocalEngineChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic, apple, mlx
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .automatic: "Automatycznie"
        case .apple: "Apple Intelligence"
        case .mlx: "Model pobrany (MLX)"
        }
    }
}

/// Obsługa polecenia modelem na urządzeniu: decyzja → walidacja → wykonanie narzędzia → potwierdzenie.
@MainActor
final class LocalAssistant {
    enum Engine: Equatable {
        case apple
        case mlx(LocalModelPreset)

        var displayName: String {
            switch self {
            case .apple: "Apple Intelligence"
            case .mlx(let preset): preset.displayName
            }
        }
    }

    enum Outcome {
        /// Polecenie wykonane lokalnie; `reply` do przeczytania (może być puste).
        case handled(reply: String)
        /// Przekaż do Claude (model lokalny niepewny, niedostępny albo narzędzie zwróciło błąd).
        case delegate(reason: String)
    }

    private let registry = ToolRegistry()
    static let timeout: Duration = .seconds(12)

    /// Wybiera silnik zgodnie z ustawieniami i tym, co jest dostępne w tej chwili.
    /// MLX wymaga GPU, a iOS nie pozwala używać GPU w tle – wtedy tylko Apple Intelligence.
    func engine(settings: AppSettings, isForeground: Bool) -> Engine? {
        let mlxPreset = settings.localModel
        let mlxUsable = MLXEngine.isSupported && MLXEngine.shared.isDownloaded(mlxPreset) && isForeground
        switch settings.localEngine {
        case .apple:
            return AppleFoundationEngine.isAvailable ? .apple : nil
        case .mlx:
            return mlxUsable ? .mlx(mlxPreset) : nil
        case .automatic:
            if AppleFoundationEngine.status == .ready { return .apple }
            if mlxUsable { return .mlx(mlxPreset) }
            return AppleFoundationEngine.isAvailable ? .apple : nil
        }
    }

    /// Wynik analizy polecenia (bez wykonywania) – także dla ekranu „Test modelu”.
    struct Analysis: Sendable {
        var fields: CommandFields?
        var route: LocalCommandRouter.Route
        var usedModel: Bool
        var duration: Duration
    }

    func analyze(_ command: String, engine: Engine?) async -> Analysis {
        let clock = ContinuousClock()
        let start = clock.now
        // 1) Reguły bez modelu: pytania o kalendarz nigdy nie trafiają do modelu (szybciej, bez pomyłek).
        if let route = LocalCommandRouter.preRoute(command) {
            return Analysis(fields: nil, route: route, usedModel: false, duration: clock.now - start)
        }
        guard let engine else {
            return Analysis(fields: nil, route: .delegate("brak gotowego modelu na telefonie"), usedModel: false, duration: clock.now - start)
        }
        // 2) Model: wybiera akcję i wypełnia pola tekstowe.
        let fields: CommandFields?
        do {
            fields = try await withTimeout(Self.timeout) { () async throws -> CommandFields? in
                switch engine {
                case .apple: return try await AppleFoundationEngine.decide(command)
                case .mlx(let preset): return try await MLXEngine.shared.decide(command, preset: preset)
                }
            }
        } catch {
            return Analysis(fields: nil, route: .delegate("błąd modelu lokalnego: \(error.localizedDescription)"),
                            usedModel: true, duration: clock.now - start)
        }
        guard let fields else {
            return Analysis(fields: nil, route: .delegate("model lokalny nie zwrócił polecenia"), usedModel: true, duration: clock.now - start)
        }
        // 3) Kontrola i daty/godziny liczone kodem z transkrypcji.
        return Analysis(fields: fields, route: LocalCommandRouter.route(fields, transcript: command),
                        usedModel: true, duration: clock.now - start)
    }

    func handle(_ command: String, engine: Engine?, context: ToolContext,
                onLocalSpeech: (String) async -> Void) async -> Outcome {
        let analysis = await analyze(command, engine: engine)
        guard case .run(let decision) = analysis.route else {
            if case .delegate(let reason) = analysis.route { return .delegate(reason: reason) }
            return .delegate(reason: "nieznany wynik")
        }
        let output: ToolOutput
        if let tool = localTools[decision.tool] {
            do { output = try await tool.run(decision.args, context: context) } catch { output = .error(error.localizedDescription) }
        } else {
            output = await registry.run(name: decision.tool, input: decision.args, context: context)
        }
        if output.isError { return .delegate(reason: output.modelText) }
        if let local = output.spokenLocally { await onLocalSpeech(local) }
        return .handled(reply: LocalCommandRouter.confirmation(for: decision, output: output))
    }

    /// Narzędzia dostępne tylko w trybie lokalnym.
    private let localTools: [String: any AssistantTool] = ["calendar_agenda": CalendarAgendaTool()]

    /// Wczytuje model MLX z wyprzedzeniem, by pierwsze polecenie nie czekało na załadowanie.
    func warmUp(settings: AppSettings) {
        guard settings.aiMode != .cloud, case .mlx(let preset)? = engine(settings: settings, isForeground: true) else { return }
        Task { try? await MLXEngine.shared.prepare(preset) }
    }
}

struct TimeoutError: LocalizedError {
    var errorDescription: String? { "Model lokalny odpowiadał zbyt długo." }
}

/// Wykonuje operację z limitem czasu.
@MainActor
func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { @MainActor in try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw TimeoutError() }
        return result
    }
}
