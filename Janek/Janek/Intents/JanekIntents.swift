import AppIntents

/// „Hej Janek” z przycisku Czynności (iPhone 17 Pro), ekranu blokady, Centrum sterowania lub Skrótów.
struct StartListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Słuchaj"
    static let description = IntentDescription("Otwiera Janka i od razu słucha polecenia.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AssistantController.shared.startListeningManually()
        return .result()
    }
}

/// Polecenie tekstowe – np. z automatyzacji w Skrótach („Gdy podłączę CarPlay → Zapytaj Janka”).
struct AskJanekIntent: AppIntent {
    static let title: LocalizedStringResource = "Zapytaj Janka"
    static let description = IntentDescription("Wysyła polecenie tekstowe do Janka; odpowiedź zostanie przeczytana na głos.")
    static let openAppWhenRun = true

    @Parameter(title: "Polecenie")
    var command: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AssistantController.shared.submit(text: command)
        return .result()
    }
}

struct JanekShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartListeningIntent(),
            phrases: ["Hej \(.applicationName)", "Słuchaj, \(.applicationName)"],
            shortTitle: "Hej Janek",
            systemImageName: "waveform.circle.fill"
        )
        AppShortcut(
            intent: AskJanekIntent(),
            phrases: ["Zapytaj \(.applicationName)"],
            shortTitle: "Zapytaj Janka",
            systemImageName: "text.bubble.fill"
        )
    }
}
