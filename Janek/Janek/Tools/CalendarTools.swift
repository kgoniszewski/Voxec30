import EventKit
import Foundation

/// Wspólny magazyn EventKit (kalendarz + przypomnienia).
@MainActor
final class EventStoreProvider {
    static let shared = EventStoreProvider()
    let store = EKEventStore()

    func requireEvents() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return
        case .notDetermined:
            guard try await store.requestFullAccessToEvents() else { throw ToolError.permissionDenied("Kalendarz") }
        default: throw ToolError.permissionDenied("Kalendarz")
        }
    }

    func requireReminders() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return
        case .notDetermined:
            guard try await store.requestFullAccessToReminders() else { throw ToolError.permissionDenied("Przypomnienia") }
        default: throw ToolError.permissionDenied("Przypomnienia")
        }
    }

    func describe(_ event: EKEvent) -> String {
        var line = "id=\(event.eventIdentifier ?? "?") | \(event.title ?? "(bez tytułu)") | "
        if event.isAllDay {
            line += "cały dzień \(DateParsing.iso(event.startDate).prefix(10))"
        } else {
            line += "\(DateParsing.iso(event.startDate)) – \(DateParsing.iso(event.endDate))"
        }
        if let location = event.location, !location.isEmpty { line += " | miejsce: \(location)" }
        return line
    }

    /// Szuka wydarzenia po identyfikatorze, a gdy go brak – po tytule w okolicy podanej daty.
    func findEvent(id: String?, title: String?, around date: Date?) throws -> EKEvent {
        if let id, let event = store.event(withIdentifier: id) { return event }
        guard let title else { throw ToolError.missingArgument("event_id albo title") }
        let center = date ?? .now
        let start = Calendar.current.date(byAdding: .day, value: date == nil ? -1 : -2, to: center)!
        let end = Calendar.current.date(byAdding: .day, value: date == nil ? 60 : 2, to: center)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let needle = TextNormalizer.normalize(title)
        let matches = store.events(matching: predicate)
            .filter { TextNormalizer.normalize($0.title ?? "").contains(needle) || needle.contains(TextNormalizer.normalize($0.title ?? "")) }
            .sorted { abs($0.startDate.timeIntervalSince(center)) < abs($1.startDate.timeIntervalSince(center)) }
        guard let event = matches.first else { throw ToolError.notFound("wydarzenie „\(title)”") }
        return event
    }
}

struct ListEventsTool: AssistantTool {
    let name = "calendar_list_events"
    let description = "Czyta plan dnia: zwraca wydarzenia z kalendarza w podanym przedziale czasu (np. dziś, jutro, ten tydzień). Wynik zawiera id wydarzeń potrzebne do przesuwania i odwoływania."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "start": JSONSchema.string("Początek przedziału, ISO 8601 czas lokalny, np. 2026-10-22T00:00:00"),
            "end": JSONSchema.string("Koniec przedziału, ISO 8601 czas lokalny"),
        ], required: ["start", "end"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let provider = EventStoreProvider.shared
        try await provider.requireEvents()
        let start = try input.requiredDate("start")
        let end = try input.requiredDate("end")
        let predicate = provider.store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = provider.store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else { return .ok("Brak wydarzeń w tym przedziale.") }
        return .ok(events.prefix(30).map(provider.describe).joined(separator: "\n"))
    }
}

struct CreateEventTool: AssistantTool {
    let name = "calendar_create_event"
    let description = "Zapisuje nowe spotkanie/wydarzenie w kalendarzu. Gdy użytkownik nie poda czasu trwania, przyjmij 1 godzinę."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "title": JSONSchema.string("Tytuł wydarzenia"),
            "start": JSONSchema.string("Początek, ISO 8601 czas lokalny"),
            "end": JSONSchema.string("Koniec, ISO 8601 czas lokalny (opcjonalnie)"),
            "all_day": JSONSchema.boolean("Wydarzenie całodniowe"),
            "location": JSONSchema.string("Miejsce (opcjonalnie)"),
            "notes": JSONSchema.string("Notatka (opcjonalnie)"),
            "alert_minutes_before": JSONSchema.integer("Powiadomienie N minut wcześniej (opcjonalnie)"),
        ], required: ["title", "start"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let provider = EventStoreProvider.shared
        try await provider.requireEvents()
        let event = EKEvent(eventStore: provider.store)
        event.title = try input.requiredString("title")
        event.startDate = try input.requiredDate("start")
        event.endDate = input.optionalDate("end") ?? event.startDate.addingTimeInterval(3600)
        event.isAllDay = input["all_day"]?.boolValue ?? false
        event.location = input.optionalString("location")
        event.notes = input.optionalString("notes")
        if let minutes = input["alert_minutes_before"]?.intValue {
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
        }
        event.calendar = provider.store.defaultCalendarForNewEvents
        try provider.store.save(event, span: .thisEvent, commit: true)
        return .ok("Zapisano: \(provider.describe(event))")
    }
}

struct MoveEventTool: AssistantTool {
    let name = "calendar_move_event"
    let description = "Przesuwa istniejące wydarzenie na nowy termin. Podaj event_id (z calendar_list_events) albo tytuł i przybliżoną datę."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "event_id": JSONSchema.string("Identyfikator wydarzenia"),
            "title": JSONSchema.string("Tytuł wydarzenia, gdy brak id"),
            "original_date": JSONSchema.string("Przybliżony obecny termin, ISO 8601"),
            "new_start": JSONSchema.string("Nowy początek, ISO 8601 czas lokalny"),
            "new_end": JSONSchema.string("Nowy koniec (opcjonalnie; domyślnie zachowany czas trwania)"),
        ], required: ["new_start"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let provider = EventStoreProvider.shared
        try await provider.requireEvents()
        let event = try provider.findEvent(id: input.optionalString("event_id"), title: input.optionalString("title"), around: input.optionalDate("original_date"))
        let duration = event.endDate.timeIntervalSince(event.startDate)
        event.startDate = try input.requiredDate("new_start")
        event.endDate = input.optionalDate("new_end") ?? event.startDate.addingTimeInterval(duration)
        try provider.store.save(event, span: .thisEvent, commit: true)
        return .ok("Przesunięto: \(provider.describe(event))")
    }
}

struct DeleteEventTool: AssistantTool {
    let name = "calendar_cancel_event"
    let description = "Odwołuje (usuwa) wydarzenie z kalendarza. Użyj tylko, gdy użytkownik jednoznacznie o to prosi."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "event_id": JSONSchema.string("Identyfikator wydarzenia"),
            "title": JSONSchema.string("Tytuł wydarzenia, gdy brak id"),
            "date": JSONSchema.string("Przybliżony termin, ISO 8601"),
        ])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let provider = EventStoreProvider.shared
        try await provider.requireEvents()
        let event = try provider.findEvent(id: input.optionalString("event_id"), title: input.optionalString("title"), around: input.optionalDate("date"))
        let summary = provider.describe(event)
        try provider.store.remove(event, span: .thisEvent, commit: true)
        return .ok("Odwołano: \(summary)")
    }
}

struct CreateReminderTool: AssistantTool {
    let name = "reminder_create"
    let description = "Tworzy przypomnienie w aplikacji Przypomnienia (z opcjonalnym terminem i alertem). Do budzika lub minutnika użyj alarm_set / timer_start."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "title": JSONSchema.string("Treść przypomnienia"),
            "due": JSONSchema.string("Termin, ISO 8601 czas lokalny (opcjonalnie)"),
            "notes": JSONSchema.string("Dodatkowa notatka (opcjonalnie)"),
        ], required: ["title"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let provider = EventStoreProvider.shared
        try await provider.requireReminders()
        let reminder = EKReminder(eventStore: provider.store)
        reminder.title = try input.requiredString("title")
        reminder.notes = input.optionalString("notes")
        reminder.calendar = provider.store.defaultCalendarForNewReminders()
        if let due = input.optionalDate("due") {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try provider.store.save(reminder, commit: true)
        return .ok("Utworzono przypomnienie „\(reminder.title ?? "")”" + (input.optionalDate("due").map { " na \(DateParsing.iso($0))" } ?? "") + ".")
    }
}

struct ListRemindersTool: AssistantTool {
    let name = "reminder_list"
    let description = "Zwraca niewykonane przypomnienia (opcjonalnie tylko z terminem do podanej daty)."
    var inputSchema: JSONValue {
        JSONSchema.object(["due_before": JSONSchema.string("Tylko z terminem przed tą datą, ISO 8601 (opcjonalnie)")])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let provider = EventStoreProvider.shared
        try await provider.requireReminders()
        let predicate = provider.store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: input.optionalDate("due_before"), calendars: nil)
        let lines: [String] = await withCheckedContinuation { continuation in
            provider.store.fetchReminders(matching: predicate) { reminders in
                let lines = (reminders ?? []).prefix(30).map { reminder -> String in
                    var line = reminder.title ?? "(bez tytułu)"
                    if let components = reminder.dueDateComponents, let due = Calendar.current.date(from: components) { line += " | termin \(DateParsing.iso(due))" }
                    return line
                }
                continuation.resume(returning: Array(lines))
            }
        }
        return .ok(lines.isEmpty ? "Brak niewykonanych przypomnień." : lines.joined(separator: "\n"))
    }
}
