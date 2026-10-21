import Foundation

@MainActor
final class ToolRegistry {
    let tools: [any AssistantTool] = [
        // Kalendarz i przypomnienia
        ListEventsTool(), CreateEventTool(), MoveEventTool(), DeleteEventTool(), CreateReminderTool(), ListRemindersTool(),
        // Telefon i wiadomości
        CallTool(), SendMessageTool(),
        // Nawigacja i miejsca
        NavigateTool(), NearbySearchTool(), WhereAmITool(),
        // Notatki
        CreateNoteTool(), SearchNotesTool(), ReadNoteTool(), AppendNoteTool(), DeleteNoteTool(),
        // Timery i budziki
        TimerStartTool(), AlarmSetTool(), MedicationReminderTool(), AlarmListTool(), AlarmCancelTool(),
        // Kontakty
        FindContactTool(), AddContactTool(), UpdateContactTool(),
        // Muzyka
        MusicControlTool(), PlayMusicTool(),
        // Zdrowie
        HealthSummaryTool(), WorkoutTool(),
        // Zdjęcia i dokumenty
        TakePhotoTool(), CreateTextFileTool(), CreatePDFTool(),
        // Aplikacje i skróty
        OpenAppTool(), RunShortcutTool(),
    ]

    private lazy var byName: [String: any AssistantTool] = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

    /// Definicje narzędzi w stałej kolejności (stabilny prefiks = trafienia w prompt cache).
    func definitions(model: ClaudeModel, webSearch: Bool) -> [JSONValue] {
        var definitions = tools.map(\.definition)
        if webSearch {
            definitions.append([
                "type": .string(model.webSearchToolType),
                "name": "web_search",
                "max_uses": 3,
                "user_location": ["type": "approximate", "country": "PL", "timezone": .string(TimeZone.current.identifier)],
            ])
        }
        return definitions
    }

    func run(name: String, input: JSONValue, context: ToolContext) async -> ToolOutput {
        guard let tool = byName[name] else { return .error("Nieznane narzędzie \(name).") }
        do {
            return try await tool.run(input, context: context)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
