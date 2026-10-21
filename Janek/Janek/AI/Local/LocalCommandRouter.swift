import Foundation

/// Decyzja modelu lokalnego: które narzędzie wywołać i z jakimi argumentami.
/// `tool == "claude"` oznacza „to polecenie przekaż do Claude”.
struct LocalDecision: Equatable, Sendable {
    var tool: String
    var args: JSONValue

    static let delegate = LocalDecision(tool: LocalCommandRouter.delegateTool, args: .object([:]))
    var isDelegate: Bool { tool == LocalCommandRouter.delegateTool }
}

/// Wspólna logika trybu lokalnego, niezależna od silnika (Apple Foundation Models / MLX):
/// - prompt opisujący podzbiór prostych narzędzi w zwięzłej formie (małe modele mają mało kontekstu),
/// - parsowanie i walidacja odpowiedzi JSON,
/// - krótkie potwierdzenia głosowe generowane lokalnie z szablonów (pewniejsze niż polszczyzna małego modelu).
enum LocalCommandRouter {
    static let delegateTool = "claude"

    struct Spec: Sendable {
        let name: String
        let signature: String
        let required: [String]
    }

    /// Narzędzia, które model lokalny może obsłużyć sam. Wszystko inne idzie do Claude.
    static let specs: [Spec] = [
        Spec(name: "timer_start", signature: "timer_start(seconds: liczba sekund, label?: etykieta) – minutnik", required: ["seconds"]),
        Spec(name: "alarm_set", signature: "alarm_set(time?: data ISO jednorazowo, daily_time?: \"HH:mm\" codziennie, label?) – budzik", required: []),
        Spec(name: "alarm_cancel", signature: "alarm_cancel(match?: \"minutnik\"|\"budzik\"|\"leki\"|etykieta) – odwołaj alarmy", required: []),
        Spec(name: "music_control", signature: "music_control(action: play|pause|next|previous|shuffle_on|shuffle_off|now_playing) – sterowanie muzyką", required: ["action"]),
        Spec(name: "music_play", signature: "music_play(query: wykonawca/utwór/album/playlista, kind?: artist|song|album|playlist) – włącz muzykę", required: ["query"]),
        Spec(name: "phone_call", signature: "phone_call(contact_name: imię w mianowniku lub relacja, kind?: phone|facetime) – zadzwoń", required: ["contact_name"]),
        Spec(name: "message_send", signature: "message_send(contact_name, text: dokładna treść, channel?: sms|whatsapp|telegram|signal) – wiadomość", required: ["contact_name", "text"]),
        Spec(name: "note_create", signature: "note_create(title: krótki tytuł, body: treść) – nowa notatka", required: ["title", "body"]),
        Spec(name: "note_append", signature: "note_append(title: tytuł notatki, text: co dopisać) – dopisz do notatki/listy", required: ["title", "text"]),
        Spec(name: "note_read", signature: "note_read(title?: tytuł) – przeczytaj notatkę", required: []),
        Spec(name: "reminder_create", signature: "reminder_create(title, due?: data ISO) – przypomnienie", required: ["title"]),
        Spec(name: "calendar_create_event", signature: "calendar_create_event(title, start: data ISO, end?: data ISO) – nowe spotkanie", required: ["title", "start"]),
        Spec(name: "maps_navigate", signature: "maps_navigate(destination: adres lub miejsce, mode?: driving|walking|transit|cycling) – nawigacja", required: ["destination"]),
        Spec(name: "contact_find", signature: "contact_find(name, field?: phone|email|address) – numer/adres kontaktu", required: ["name"]),
        Spec(name: "health_read", signature: "health_read(metrics: [steps|heart_rate|calories|distance], period?: today|yesterday|week) – dane zdrowia", required: ["metrics"]),
        Spec(name: "workout", signature: "workout(action: start|stop|status, activity?: running|walking|cycling|strength|yoga|swimming|other) – trening", required: ["action"]),
        Spec(name: "app_open", signature: "app_open(app_name) – otwórz aplikację", required: ["app_name"]),
        Spec(name: "shortcut_run", signature: "shortcut_run(shortcut_name) – uruchom skrót z aplikacji Skróty", required: ["shortcut_name"]),
    ]

    static let toolNames: [String] = specs.map(\.name) + [delegateTool]

    // MARK: Prompt

    static func instructions(now: Date = .now, calendar: Calendar = .current) -> String {
        """
        Jesteś modułem rozpoznawania poleceń polskiego asystenta głosowego Janek. \
        Zamień polecenie użytkownika (transkrypcję mowy) na JSON: {"tool": "<nazwa>", "args": {…}}.
        Jeśli polecenie nie pasuje dokładnie do jednego narzędzia, jest pytaniem o wiedzę, rozmową, \
        wymaga kilku kroków albo nie masz pewności – zwróć {"tool": "claude", "args": {}}.

        Narzędzia:
        \(specs.map { "- " + $0.signature }.joined(separator: "\n"))

        Zasady:
        - Daty w formacie ISO 8601 czasu lokalnego, np. 2026-10-22T09:00:00. „rano” = 8:00, „po południu” = 15:00, „wieczorem” = 19:00.
        - Imiona w mianowniku („do Ani” → „Ania”, „Tomkowi” → „Tomek”); relacje dosłownie („mama”).
        - Czas minutnika zawsze w sekundach (10 minut = 600).
        - Odpowiedz wyłącznie jednym obiektem JSON, bez komentarzy.

        \(dateContext(now: now, calendar: calendar))

        Przykłady:
        „nastaw minutnik na pięć minut” → {"tool":"timer_start","args":{"seconds":300}}
        „zadzwoń do mamy” → {"tool":"phone_call","args":{"contact_name":"mama"}}
        „dopisz mleko do listy zakupów” → {"tool":"note_append","args":{"title":"lista zakupów","text":"mleko"}}
        „pauza” → {"tool":"music_control","args":{"action":"pause"}}
        „jaka jest stolica Australii” → {"tool":"claude","args":{}}
        „przesuń spotkanie z Anią na piątek” → {"tool":"claude","args":{}}
        """
    }

    /// Tabela najbliższych dni – małe modele słabo liczą daty, więc podajemy je wprost.
    static func dateContext(now: Date, calendar: Calendar) -> String {
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "pl_PL")
        weekday.timeZone = calendar.timeZone
        weekday.dateFormat = "EEEE"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = calendar.timeZone
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"

        let names = ["dziś", "jutro", "pojutrze"]
        let start = calendar.startOfDay(for: now)
        let lines = (0..<8).map { offset -> String in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            let label = offset < names.count ? "\(names[offset]) (\(weekday.string(from: date)))" : weekday.string(from: date)
            return "\(label): \(day.string(from: date))"
        }
        return "Teraz jest \(time.string(from: now)). Kalendarz:\n" + lines.joined(separator: "\n")
    }

    // MARK: Parsowanie i walidacja

    /// Wyciąga pierwszy obiekt JSON z tekstu modelu (pomija <think>…</think>, bloki ```json itp.).
    static func parse(_ text: String) -> LocalDecision? {
        var source = text
        if let thinkEnd = source.range(of: "</think>") { source = String(source[thinkEnd.upperBound...]) }
        guard let json = firstJSONObject(in: source),
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
              let tool = value["tool"]?.stringValue else { return nil }
        return LocalDecision(tool: tool, args: value["args"] ?? .object([:]))
    }

    static func parse(tool: String, argumentsJSON: String) -> LocalDecision? {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let args: JSONValue
        if trimmed.isEmpty {
            args = .object([:])
        } else if let json = firstJSONObject(in: trimmed), let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) {
            args = value
        } else {
            return nil
        }
        return LocalDecision(tool: tool, args: args)
    }

    static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Sprawdza decyzję; zwraca `nil`, gdy jest niepewna – wtedy polecenie przejmuje Claude.
    static func validate(_ decision: LocalDecision) -> LocalDecision? {
        if decision.isDelegate { return decision }
        guard let spec = specs.first(where: { $0.name == decision.tool }),
              case .object(var args) = decision.args else { return nil }
        // Usuń puste wartości (małe modele lubią zwracać "label": "").
        args = args.filter { _, value in
            if case .string(let string) = value { return !string.trimmingCharacters(in: .whitespaces).isEmpty }
            if case .null = value { return false }
            return true
        }
        for key in spec.required where args[key] == nil { return nil }

        switch spec.name {
        case "timer_start":
            guard let seconds = args["seconds"]?.intValue, (1...86_400).contains(seconds) else { return nil }
            args["seconds"] = .number(Double(seconds))
        case "alarm_set":
            if let time = args["time"]?.stringValue {
                guard let date = DateParsing.parse(time), date > .now else { return nil }
            } else if let daily = args["daily_time"]?.stringValue {
                let parts = daily.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
            } else {
                return nil
            }
        case "calendar_create_event":
            guard let start = args["start"]?.stringValue, DateParsing.parse(start) != nil else { return nil }
            if let end = args["end"]?.stringValue, DateParsing.parse(end) == nil { args["end"] = nil }
        case "reminder_create":
            if let due = args["due"]?.stringValue, DateParsing.parse(due) == nil { return nil }
        case "music_control":
            let actions = ["play", "pause", "next", "previous", "shuffle_on", "shuffle_off", "now_playing"]
            guard let action = args["action"]?.stringValue, actions.contains(action) else { return nil }
        case "workout":
            guard let action = args["action"]?.stringValue, ["start", "stop", "status"].contains(action) else { return nil }
        case "health_read":
            if case .string(let single) = args["metrics"] { args["metrics"] = .array([.string(single)]) }
            guard let metrics = args["metrics"]?.arrayValue, !metrics.isEmpty else { return nil }
        default:
            break
        }
        return LocalDecision(tool: spec.name, args: .object(args))
    }

    // MARK: Potwierdzenia

    /// Krótka odpowiedź do przeczytania po udanym wykonaniu narzędzia.
    /// Pusta, gdy narzędzie samo przeczytało wynik (`spokenLocally`).
    static func confirmation(for decision: LocalDecision, output: ToolOutput) -> String {
        if output.spokenLocally != nil { return "" }
        let args = decision.args
        switch decision.tool {
        case "timer_start":
            return "Minutnik na \(spokenDuration(args["seconds"]?.intValue ?? 0))."
        case "alarm_set":
            if let daily = args["daily_time"]?.stringValue { return "Budzik codziennie o \(daily)." }
            if let date = args["time"]?.stringValue.flatMap({ DateParsing.parse($0) }) {
                return "Budzik na \(DateParsing.spoken(date))."
            }
            return "Budzik ustawiony."
        case "alarm_cancel": return "Odwołane."
        case "music_control":
            switch args["action"]?.stringValue {
            case "play": return "Gram."
            case "pause": return "Zatrzymane."
            case "next": return "Następny utwór."
            case "previous": return "Poprzedni utwór."
            case "now_playing": return output.modelText
            default: return "Gotowe."
            }
        case "music_play": return "Włączam \(args["query"]?.stringValue ?? "muzykę")."
        case "phone_call": return "Dzwonię."
        case "message_send": return "Wiadomość gotowa, zatwierdź wysłanie."
        case "note_create": return "Zanotowane."
        case "note_append": return output.modelText
        case "reminder_create":
            let title = args["title"]?.stringValue ?? ""
            if let due = args["due"]?.stringValue.flatMap({ DateParsing.parse($0) }) {
                return "Przypomnę: \(title), \(DateParsing.spoken(due))."
            }
            return "Dodałem przypomnienie: \(title)."
        case "calendar_create_event":
            let title = args["title"]?.stringValue ?? "spotkanie"
            if let start = args["start"]?.stringValue.flatMap({ DateParsing.parse($0) }) {
                return "Zapisane w kalendarzu: \(title), \(DateParsing.spoken(start))."
            }
            return "Zapisane w kalendarzu."
        case "maps_navigate": return "Prowadzę do: \(args["destination"]?.stringValue ?? "celu")."
        case "workout":
            switch args["action"]?.stringValue {
            case "start": return "Rozpoczynam trening."
            default: return output.modelText
            }
        case "app_open": return "Otwieram \(args["app_name"]?.stringValue ?? "aplikację")."
        case "shortcut_run": return "Uruchamiam skrót \(args["shortcut_name"]?.stringValue ?? "")."
        default: return "Gotowe."
        }
    }

    static func spokenDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60, rest = seconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append(plural(hours, "godzinę", "godziny", "godzin")) }
        if minutes > 0 { parts.append(plural(minutes, "minutę", "minuty", "minut")) }
        if rest > 0 || parts.isEmpty { parts.append(plural(rest, "sekundę", "sekundy", "sekund")) }
        return parts.joined(separator: " i ")
    }

    /// Polska odmiana liczebników: 1 minutę, 2–4 minuty, 5+ minut (ale 22 minuty, 12 minut).
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        if n == 1 { return "1 \(one)" }
        let lastDigit = n % 10, lastTwo = n % 100
        let form = (2...4).contains(lastDigit) && !(12...14).contains(lastTwo) ? few : many
        return "\(n) \(form)"
    }
}
