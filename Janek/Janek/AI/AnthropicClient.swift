import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // tylko Linux (testy logiki poza Xcode)
#endif

/// Modele Claude do wyboru w ustawieniach.
enum ClaudeModel: String, CaseIterable, Identifiable, Sendable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus: "Claude Opus 5.5"
        case .sonnet: "Claude Sonnet 5.5"
        case .haiku: "Claude Haiku 5.5"
        }
    }

    var subtitle: String {
        switch self {
        case .opus: "Najlepiej rozumie złożone polecenia · $4 / $20 za 1M tokenów"
        case .sonnet: "Szybszy, tańszy · $2 / $10 za 1M tokenów"
        case .haiku: "Najszybszy i najtańszy · $0,10 / $0,50 za 1M tokenów"
        }
    }

    /// Server-side fallback po odmowie klasyfikatora (`fallbacks: "default"`) – nie dla Haiku.
    var supportsServerFallback: Bool { self != .haiku }

    /// Wariant narzędzia wyszukiwania w sieci obsługiwany przez model.
    var webSearchToolType: String {
        self == .haiku ? "web_search_20250305" : "web_search_20260209"
    }
}

enum ClaudeEffort: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .low: "Niski (najszybciej)"
        case .medium: "Średni"
        case .high: "Wysoki (najdokładniej)"
        }
    }
}

struct AnthropicResponse: Sendable {
    let id: String
    let model: String
    let stopReason: String?
    /// Surowe bloki treści – odsyłane bez zmian w historii rozmowy.
    let content: [JSONValue]
    let inputTokens: Int
    let outputTokens: Int

    var text: String {
        content.compactMap { block -> String? in
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var toolUses: [(id: String, name: String, input: JSONValue)] {
        content.compactMap { block in
            guard block["type"]?.stringValue == "tool_use",
                  let id = block["id"]?.stringValue,
                  let name = block["name"]?.stringValue else { return nil }
            return (id, name, block["input"] ?? .object([:]))
        }
    }
}

enum AnthropicError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited
    case overloaded
    case badRequest(String)
    case server(Int, String)
    case network(Error)
    case decoding

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Brak klucza API Anthropic. Wklej go w ustawieniach."
        case .invalidAPIKey: "Klucz API jest nieprawidłowy albo został unieważniony."
        case .rateLimited: "Przekroczono limit zapytań do Anthropic. Spróbuj za chwilę."
        case .overloaded: "Serwery Anthropic są teraz przeciążone. Spróbuj za chwilę."
        case .badRequest(let message): "Błędne zapytanie: \(message)"
        case .server(let code, _): "Błąd serwera Anthropic (\(code))."
        case .network: "Brak połączenia z internetem."
        case .decoding: "Nie udało się odczytać odpowiedzi modelu."
        }
    }

    /// Komunikat do przeczytania na głos.
    var spokenDescription: String {
        switch self {
        case .missingAPIKey: "Nie mam klucza API. Wklej go w ustawieniach aplikacji."
        case .invalidAPIKey: "Twój klucz API nie działa. Sprawdź go w ustawieniach."
        case .rateLimited, .overloaded: "Serwer jest teraz zajęty. Spróbuj za chwilę."
        case .network: "Nie mam połączenia z internetem."
        default: "Coś poszło nie tak. Spróbuj jeszcze raz."
        }
    }
}

/// Minimalny klient Messages API (https://api.anthropic.com/v1/messages) oparty na URLSession.
/// Dla Swift nie ma oficjalnego SDK, więc używamy surowego HTTP.
struct AnthropicClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    let apiKey: String
    var session: URLSession = .shared
    var maxRetries = 2

    struct Request: Sendable {
        var model: ClaudeModel
        var effort: ClaudeEffort
        var system: String
        var tools: [JSONValue]
        var messages: [JSONValue]
        var maxTokens = 16_000
    }

    func send(_ request: Request) async throws -> AnthropicResponse {
        guard !apiKey.isEmpty else { throw AnthropicError.missingAPIKey }
        let urlRequest = try makeURLRequest(request)

        var attempt = 0
        while true {
            do {
                return try await perform(urlRequest)
            } catch let error as AnthropicError {
                let retryable: Bool
                switch error {
                case .rateLimited, .overloaded, .network: retryable = true
                case .server(let code, _): retryable = code >= 500
                default: retryable = false
                }
                guard retryable, attempt < maxRetries else { throw error }
                attempt += 1
                try await Task.sleep(for: .milliseconds(600 * (1 << attempt)))
            }
        }
    }

    func makeURLRequest(_ request: Request) throws -> URLRequest {
        var body: [String: JSONValue] = [
            "model": .string(request.model.rawValue),
            "max_tokens": .number(Double(request.maxTokens)),
            // Stały prompt systemowy + narzędzia są cache'owane (tools → system → messages).
            "system": [["type": "text", "text": .string(request.system), "cache_control": ["type": "ephemeral"]]],
            "messages": .array(request.messages),
            "output_config": ["effort": .string(request.effort.rawValue)],
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools)
        }
        if request.model.supportsServerFallback {
            body["fallbacks"] = "default"
        }

        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 90
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if request.model.supportsServerFallback {
            urlRequest.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys] // deterministyczne bajty = trafienia w prompt cache
        urlRequest.httpBody = try encoder.encode(JSONValue.object(body))
        return urlRequest
    }

    private func perform(_ urlRequest: URLRequest) async throws -> AnthropicResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw AnthropicError.network(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]?["message"]?.stringValue
                ?? String(decoding: data, as: UTF8.self)
            switch status {
            case 401, 403: throw AnthropicError.invalidAPIKey
            case 429: throw AnthropicError.rateLimited
            case 529: throw AnthropicError.overloaded
            case 400..<500: throw AnthropicError.badRequest(message)
            default: throw AnthropicError.server(status, message)
            }
        }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> AnthropicResponse {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let content = json["content"]?.arrayValue else {
            throw AnthropicError.decoding
        }
        return AnthropicResponse(
            id: json["id"]?.stringValue ?? "",
            model: json["model"]?.stringValue ?? "",
            stopReason: json["stop_reason"]?.stringValue,
            content: content,
            inputTokens: json["usage"]?["input_tokens"]?.intValue ?? 0,
            outputTokens: json["usage"]?["output_tokens"]?.intValue ?? 0
        )
    }

    /// Szybki test klucza (1 token wyjścia) – używany w ustawieniach.
    func verifyKey() async throws {
        _ = try await send(Request(
            model: .haiku, effort: .low, system: "Odpowiedz jednym słowem.",
            tools: [], messages: [["role": "user", "content": "ping"]], maxTokens: 16
        ))
    }
}
