import Foundation
import os

struct AgentReply: Sendable {
    var text: String
    /// Janek zadał pytanie – nasłuchujemy odpowiedzi bez słowa-klucza.
    var expectsFollowUp: Bool
}

/// Pętla agenta: wysyła polecenie do Claude, wykonuje wywołania narzędzi i zwraca odpowiedź do przeczytania.
/// Historia jest tylko dopisywana (append-only) – nie edytujemy wcześniejszych tur, co zachowuje
/// ważność bloków `thinking` i trafienia w prompt cache.
@MainActor
final class ConversationAgent {
    private let registry = ToolRegistry()
    private let logger = Logger(subsystem: "pl.janek.assistant", category: "agent")
    private var messages: [JSONValue] = []
    /// Wyniki narzędzi z tury zakończonej lokalnie – dołączane do następnej wiadomości użytkownika.
    private var pendingToolResults: [JSONValue] = []
    private var lastActivity = Date.distantPast
    private var sessionModel: ClaudeModel?
    private var sessionWebSearch: Bool?

    static let sessionTimeout: TimeInterval = 180
    static let maxIterations = 8

    var onLocalSpeech: ((String) async -> Void)?
    var onToolActivity: ((String) -> Void)?

    func reset() {
        messages.removeAll()
        pendingToolResults.removeAll()
    }

    func send(_ transcript: String, settings: AppSettings, context: ToolContext, inCar: Bool) async throws -> AgentReply {
        let model = settings.model
        // Nowa sesja po przerwie, zmianie modelu lub zestawu narzędzi (narzędzia są częścią prefiksu).
        if Date.now.timeIntervalSince(lastActivity) > Self.sessionTimeout || model != sessionModel
            || settings.webSearchEnabled != sessionWebSearch || messages.count > 60 {
            reset()
            sessionModel = model
            sessionWebSearch = settings.webSearchEnabled
        }
        lastActivity = .now

        let client = AnthropicClient(apiKey: KeychainStore.apiKey ?? "")
        let tools = registry.definitions(model: model, webSearch: settings.webSearchEnabled)

        var userContent = pendingToolResults
        pendingToolResults.removeAll()
        userContent.append(["type": "text", "text": .string(SystemPrompt.userTurn(transcript, inCar: inCar))])
        messages.append(["role": "user", "content": .array(userContent)])

        var spokenLocally: [String] = []
        for _ in 0..<Self.maxIterations {
            let response = try await client.send(.init(
                model: model, effort: settings.effort, system: SystemPrompt.text, tools: tools, messages: messages
            ))
            logger.info("stop=\(response.stopReason ?? "-", privacy: .public) in=\(response.inputTokens) out=\(response.outputTokens)")
            lastActivity = .now

            switch response.stopReason {
            case "refusal":
                // Odmowa: nie dopisujemy tej tury do historii.
                reset()
                return AgentReply(text: "Przepraszam, w tym nie mogę pomóc.", expectsFollowUp: false)
            case "pause_turn":
                // Wyszukiwanie w sieci trwa dłużej – kontynuujemy tę samą turę.
                messages.append(["role": "assistant", "content": .array(response.content)])
                continue
            default:
                break
            }

            messages.append(["role": "assistant", "content": .array(response.content)])

            let toolUses = response.toolUses
            guard response.stopReason == "tool_use", !toolUses.isEmpty else {
                let text = response.text.isEmpty ? (spokenLocally.isEmpty ? "Gotowe." : "") : response.text
                return AgentReply(text: text, expectsFollowUp: text.hasSuffix("?"))
            }

            var results: [JSONValue] = []
            var allEndTurn = true
            for toolUse in toolUses {
                onToolActivity?(toolUse.name)
                let output = await registry.run(name: toolUse.name, input: toolUse.input, context: context)
                logger.info("tool \(toolUse.name, privacy: .public) error=\(output.isError)")
                if let local = output.spokenLocally {
                    spokenLocally.append(local)
                    await onLocalSpeech?(local)
                }
                allEndTurn = allEndTurn && output.endsTurn && !output.isError
                results.append([
                    "type": "tool_result",
                    "tool_use_id": .string(toolUse.id),
                    "content": .string(output.modelText),
                    "is_error": .bool(output.isError),
                ])
            }

            if allEndTurn {
                // Wynik został już przeczytany lokalnie – nie wysyłamy go do modelu teraz.
                pendingToolResults = results
                return AgentReply(text: "", expectsFollowUp: false)
            }
            messages.append(["role": "user", "content": .array(results)])
        }
        return AgentReply(text: "To zajmuje mi za dużo kroków. Spróbuj prościej.", expectsFollowUp: false)
    }
}
