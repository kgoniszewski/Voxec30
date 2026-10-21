import Foundation

/// Wynik wykonania narzędzia.
struct ToolOutput: Sendable {
    /// Treść odsyłana do modelu w bloku `tool_result`.
    var modelText: String
    /// Tekst czytany użytkownikowi bezpośrednio na telefonie – NIE trafia do Anthropic
    /// (np. dane zdrowotne, numery telefonów, treść notatek).
    var spokenLocally: String?
    /// Gdy `true`, nie wołamy ponownie modelu – odpowiedź została już przeczytana lokalnie.
    var endsTurn = false
    var isError = false

    static func ok(_ text: String) -> ToolOutput { ToolOutput(modelText: text) }

    static func error(_ text: String) -> ToolOutput { ToolOutput(modelText: text, isError: true) }

    /// Odczyt prywatnych danych: model dostaje tylko potwierdzenie.
    static func privateReadout(_ spoken: String, summaryForModel: String = "Wynik został przeczytany użytkownikowi bezpośrednio na telefonie. Nie powtarzaj go.") -> ToolOutput {
        ToolOutput(modelText: summaryForModel, spokenLocally: spoken, endsTurn: true)
    }
}

enum ToolError: LocalizedError {
    case missingArgument(String)
    case permissionDenied(String)
    case notFound(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name): "Brak wymaganego argumentu: \(name)."
        case .permissionDenied(let what): "Brak zgody na dostęp: \(what). Użytkownik może ją włączyć w Ustawieniach iOS → Janek."
        case .notFound(let what): "Nie znaleziono: \(what)."
        case .unavailable(let what): "Niedostępne: \(what)."
        }
    }
}

/// Jedno narzędzie udostępniane modelowi Claude.
@MainActor
protocol AssistantTool {
    var name: String { get }
    var description: String { get }
    var inputSchema: JSONValue { get }
    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput
}

extension AssistantTool {
    var definition: JSONValue {
        ["name": .string(name), "description": .string(description), "input_schema": inputSchema]
    }
}

/// To, czego narzędzia potrzebują od aplikacji (otwieranie URL-i, prezentowanie arkuszy).
@MainActor
protocol ToolContext: AnyObject {
    var isAppInForeground: Bool { get }
    func open(_ url: URL) async -> Bool
    func present(_ sheet: PresentedSheet)
}

/// Arkusze UI, których wymagają niektóre akcje (iOS nie pozwala ich wykonać „po cichu”).
enum PresentedSheet: Identifiable {
    case camera
    case messageComposer(recipients: [String], body: String)
    case document(URL)

    var id: String {
        switch self {
        case .camera: "camera"
        case .messageComposer(let recipients, _): "sms-\(recipients.joined())"
        case .document(let url): "doc-\(url.path)"
        }
    }
}

extension JSONValue {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw ToolError.missingArgument(key)
        }
        return value
    }

    func optionalString(_ key: String) -> String? {
        guard let value = self[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    func requiredDate(_ key: String) throws -> Date {
        let text = try requiredString(key)
        guard let date = DateParsing.parse(text) else { throw ToolError.missingArgument("\(key) (format ISO 8601)") }
        return date
    }

    func optionalDate(_ key: String) -> Date? {
        optionalString(key).flatMap { DateParsing.parse($0) }
    }
}
