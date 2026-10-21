import Foundation
import SwiftData

struct CreateNoteTool: AssistantTool {
    let name = "note_create"
    let description = "Zapisuje nową notatkę we własnej bazie Janka (na telefonie). Nadaj krótki tytuł, jeśli użytkownik go nie poda."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "title": JSONSchema.string("Krótki tytuł notatki"),
            "body": JSONSchema.string("Treść notatki – dokładnie to, co podyktował użytkownik, z poprawną interpunkcją"),
        ], required: ["title", "body"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let note = Note(title: try input.requiredString("title"), body: try input.requiredString("body"))
        NotesDatabase.context.insert(note)
        try NotesDatabase.context.save()
        return .ok("Zapisano notatkę „\(note.title)”.")
    }
}

struct SearchNotesTool: AssistantTool {
    let name = "note_search"
    let description = "Wyszukuje notatki po słowach kluczowych (lub zwraca ostatnie, gdy zapytanie jest puste). Zwraca tylko tytuły i daty – do odczytania treści użyj note_read."
    var inputSchema: JSONValue {
        JSONSchema.object(["query": JSONSchema.string("Słowa kluczowe; puste = najnowsze notatki")])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let notes = try NotesDatabase.search(input.optionalString("query") ?? "").prefix(10)
        guard !notes.isEmpty else { return .ok("Brak pasujących notatek.") }
        return .ok(notes.map { "„\($0.title)” (zmieniona \(DateParsing.iso($0.updatedAt)))" }.joined(separator: "\n"))
    }
}

struct ReadNoteTool: AssistantTool {
    let name = "note_read"
    let description = "Czyta użytkownikowi treść notatki. Treść jest czytana lokalnie i nie trafia do modelu."
    var inputSchema: JSONValue {
        JSONSchema.object(["title": JSONSchema.string("Tytuł albo słowa kluczowe notatki; puste = ostatnia notatka")])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        guard let note = try NotesDatabase.search(input.optionalString("title") ?? "").first else {
            throw ToolError.notFound("notatka")
        }
        return .privateReadout("Notatka \(note.title). \(note.body)",
                               summaryForModel: "Przeczytano użytkownikowi notatkę „\(note.title)”.")
    }
}

struct AppendNoteTool: AssistantTool {
    let name = "note_append"
    let description = "Dopisuje tekst na końcu istniejącej notatki (np. „dopisz mleko do listy zakupów”). Jeśli notatki nie ma, tworzy ją."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "title": JSONSchema.string("Tytuł lub słowa kluczowe notatki"),
            "text": JSONSchema.string("Tekst do dopisania"),
        ], required: ["title", "text"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let title = try input.requiredString("title")
        let text = try input.requiredString("text")
        if let note = try NotesDatabase.search(title).first {
            note.body += (note.body.hasSuffix("\n") || note.body.isEmpty ? "" : "\n") + text
            note.updatedAt = .now
            try NotesDatabase.context.save()
            return .ok("Dopisano do notatki „\(note.title)”.")
        }
        let note = Note(title: title.prefix(1).uppercased() + title.dropFirst(), body: text)
        NotesDatabase.context.insert(note)
        try NotesDatabase.context.save()
        return .ok("Nie było takiej notatki – utworzono nową „\(note.title)”.")
    }
}

struct DeleteNoteTool: AssistantTool {
    let name = "note_delete"
    let description = "Usuwa notatkę. Użyj tylko na wyraźną prośbę użytkownika."
    var inputSchema: JSONValue {
        JSONSchema.object(["title": JSONSchema.string("Tytuł lub słowa kluczowe notatki")], required: ["title"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        guard let note = try NotesDatabase.search(try input.requiredString("title")).first else { throw ToolError.notFound("notatka") }
        let title = note.title
        NotesDatabase.context.delete(note)
        try NotesDatabase.context.save()
        return .ok("Usunięto notatkę „\(title)”.")
    }
}
