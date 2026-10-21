import Foundation

/// Polecenie rozłożone przez model lokalny na proste pola.
/// Model wybiera tylko *co* zrobić i wypełnia pola tekstowe – daty, godziny i czasy trwania
/// liczy `PolishTimeParser` z samej transkrypcji (małe modele często się na nich mylą).
struct CommandFields: Codable, Equatable, Sendable {
    var tool: String
    var title: String?
    var text: String?
    var person: String?
    var day: String?
    var hour: Int?
    var minute: Int?
    var durationSeconds: Int?
    var option: String?

    enum CodingKeys: String, CodingKey {
        case tool, title, text, person, day, hour, minute, option
        case durationSeconds = "duration_seconds"
    }

    init(tool: String, title: String? = nil, text: String? = nil, person: String? = nil, day: String? = nil,
         hour: Int? = nil, minute: Int? = nil, durationSeconds: Int? = nil, option: String? = nil) {
        self.tool = tool
        self.title = Self.clean(title)
        self.text = Self.clean(text)
        self.person = Self.clean(person)
        self.day = Self.clean(day)
        self.hour = hour.flatMap { (0...23).contains($0) ? $0 : nil }
        self.minute = minute.flatMap { (0...59).contains($0) ? $0 : nil }
        self.durationSeconds = durationSeconds.flatMap { $0 > 0 ? $0 : nil }
        self.option = Self.clean(option)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
        func int(_ key: CodingKeys) -> Int? {
            (try? c.decodeIfPresent(Int.self, forKey: key)) ?? string(key).flatMap { Int($0) }
        }
        self.init(tool: try c.decode(String.self, forKey: .tool), title: string(.title), text: string(.text),
                  person: string(.person), day: string(.day), hour: int(.hour), minute: int(.minute),
                  durationSeconds: int(.durationSeconds), option: string(.option))
    }

    /// Puste wartości i znaczniki „brak” traktujemy jak brak pola.
    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !["brak", "none", "null", "-"].contains(value.lowercased()) else { return nil }
        return value
    }
}

/// Decyzja: które narzędzie wywołać i z jakimi argumentami.
struct LocalDecision: Equatable, Sendable {
    var tool: String
    var args: JSONValue
}

/// Wspólna logika trybu lokalnego, niezależna od silnika (Apple Foundation Models / MLX).
enum LocalCommandRouter {
    static let delegateTool = "claude"

    enum Route: Equatable, Sendable {
        case run(LocalDecision)
        case delegate(String)
    }

    /// Narzędzia dostępne dla modelu lokalnego i pola, których używają.
    static let tools: [(name: String, usage: String)] = [
        ("calendar_agenda", "co mam w kalendarzu / plan dnia (pytania o wydarzenia); pola: day"),
        ("calendar_create_event", "dodaj wydarzenie/spotkanie do kalendarza; pola: title, day, hour, minute"),
        ("reminder_create", "przypomnienie w aplikacji Przypomnienia; pola: title, day, hour, minute"),
        ("alarm_set", "budzik na godzinę; pola: day, hour, minute, title; option=daily dla codziennego"),
        ("timer_start", "minutnik; pola: duration_seconds, title"),
        ("alarm_cancel", "odwołaj budzik/minutnik; pola: title (np. minutnik, budzik)"),
        ("music_control", "sterowanie muzyką; option: play|pause|next|previous|shuffle_on|shuffle_off|now_playing"),
        ("music_play", "włącz wykonawcę/utwór/album/playlistę; pola: title; option: artist|song|album|playlist"),
        ("phone_call", "zadzwoń; pola: person; option: phone|facetime"),
        ("message_send", "wyślij wiadomość; pola: person, text; option: sms|whatsapp|telegram|signal"),
        ("note_create", "nowa notatka; pola: title, text"),
        ("note_append", "dopisz do notatki/listy; pola: title (nazwa notatki), text (co dopisać)"),
        ("note_read", "przeczytaj notatkę; pola: title"),
        ("maps_navigate", "nawigacja; pola: title (cel); option: driving|walking|transit|cycling"),
        ("contact_find", "numer/adres kontaktu; pola: person; option: phone|email|address"),
        ("health_read", "kroki, puls, kalorie; option: steps|heart_rate|calories|distance; pola: day"),
        ("workout", "trening; option: start|stop|status; pola: title (rodzaj, np. bieg)"),
        ("app_open", "otwórz aplikację; pola: title (nazwa aplikacji)"),
        ("shortcut_run", "uruchom skrót z aplikacji Skróty; pola: title (nazwa skrótu)"),
    ]

    static let toolNames: [String] = tools.map(\.name) + [delegateTool]

    static let options = [
        "play", "pause", "next", "previous", "shuffle_on", "shuffle_off", "now_playing",
        "artist", "song", "album", "playlist", "phone", "facetime", "sms", "whatsapp", "telegram", "signal",
        "driving", "walking", "transit", "cycling", "email", "address", "steps", "heart_rate", "calories",
        "distance", "start", "stop", "status", "daily",
    ]

    static let dayValues = ["dziś", "jutro", "pojutrze", "wczoraj", "poniedziałek", "wtorek", "środa",
                            "czwartek", "piątek", "sobota", "niedziela"]

    // MARK: Prompt

    static func instructions(now: Date = .now, calendar: Calendar = .current) -> String {
        """
        Jesteś modułem rozpoznawania poleceń polskiego asystenta głosowego Janek. \
        Rozłóż polecenie użytkownika (transkrypcję mowy) na pola obiektu JSON: \
        tool, title, text, person, day, hour, minute, duration_seconds, option. Pomiń pola, których polecenie nie dotyczy.

        tool – jedno z:
        \(tools.map { "- \($0.name): \($0.usage)" }.joined(separator: "\n"))
        - claude: wszystko inne – pytania o wiedzę, rozmowa, przesuwanie lub odwoływanie spotkań, \
        polecenia złożone albo niejasne. W razie wątpliwości wybierz claude.

        Zasady:
        - Pytanie („czy mam…”, „co mam…”, „jakie…”) nigdy nie dodaje ani nie zmienia niczego.
        - person: imię w mianowniku („do Ani” → „Ania”); relacje dosłownie („mama”).
        - day: \(dayValues.joined(separator: ", ")).
        - hour 0–23, minute 0–59; „wieczorem” i „po południu” to godziny po 12.
        - title: krótko, bez słów „wydarzenie”, „spotkanie w kalendarzu”, „przypomnienie”.
        - Odpowiedz wyłącznie jednym obiektem JSON.

        \(dateContext(now: now, calendar: calendar))

        Przykłady:
        „nastaw minutnik na pięć minut” → {"tool":"timer_start","duration_seconds":300}
        „dodaj jutro spotkanie z Anią o dziesiątej” → {"tool":"calendar_create_event","title":"Spotkanie z Anią","day":"jutro","hour":10,"minute":0}
        „czy mam dziś coś w kalendarzu” → {"tool":"calendar_agenda","day":"dziś"}
        „zadzwoń do mamy” → {"tool":"phone_call","person":"mama"}
        „dopisz mleko do listy zakupów” → {"tool":"note_append","title":"lista zakupów","text":"mleko"}
        „pauza” → {"tool":"music_control","option":"pause"}
        „jaka jest stolica Australii” → {"tool":"claude"}
        """
    }

    static func dateContext(now: Date, calendar: Calendar) -> String {
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "pl_PL")
        weekday.timeZone = calendar.timeZone
        weekday.dateFormat = "EEEE"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"
        return "Teraz: \(weekday.string(from: now)), godzina \(time.string(from: now))."
    }

    // MARK: Parsowanie odpowiedzi tekstowej (gdy silnik nie wymusza struktury)

    static func parse(_ text: String) -> CommandFields? {
        var source = text
        if let thinkEnd = source.range(of: "</think>") { source = String(source[thinkEnd.upperBound...]) }
        guard let json = firstJSONObject(in: source) else { return nil }
        return try? JSONDecoder().decode(CommandFields.self, from: Data(json.utf8))
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

    // MARK: Reguły niezależne od modelu

    static let politeMarkers: Set<String> = ["mozesz", "moglbys", "moglabys", "mozna", "prosze", "zechcesz", "potrafisz"]
    static let questionStarters: Set<String> = ["czy", "jakie", "jaki", "jaka", "jakich", "co", "kiedy", "ile", "gdzie", "ktora", "ktore", "mam", "masz"]

    /// Pytanie (a nie polecenie) – takie nigdy nie może niczego tworzyć ani wysyłać.
    static func isQuestion(_ transcript: String) -> Bool {
        let words = TextNormalizer.words(transcript)
        guard let first = words.first else { return false }
        if words.contains(where: politeMarkers.contains) { return false }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return true }
        if first == "o", words.count > 1, words[1] == "ktorej" { return true }
        return questionStarters.contains(first)
    }

    static let agendaStems = ["kalendarz", "wydarzen", "spotkan", "plan", "zaplanowan", "terminy", "zajet", "wolny", "wolne"]

    /// Polecenia, które można obsłużyć w ogóle bez modelu (szybciej i pewniej).
    static func preRoute(_ transcript: String, now: Date = .now, calendar: Calendar = .current) -> Route? {
        let words = TextNormalizer.words(transcript)
        let mentionsAgenda = words.contains { word in agendaStems.contains { word.hasPrefix($0) } }
            || TextNormalizer.normalize(transcript).contains("co mam")
        if isQuestion(transcript), mentionsAgenda {
            return route(CommandFields(tool: "calendar_agenda"), transcript: transcript, now: now, calendar: calendar)
        }
        return nil
    }

    /// Akcje, które coś zmieniają lub wysyłają – niedozwolone dla pytań.
    static let mutatingTools: Set<String> = [
        "calendar_create_event", "reminder_create", "alarm_set", "timer_start", "alarm_cancel", "message_send",
        "phone_call", "note_create", "note_append", "workout",
    ]

    /// Słowa, które muszą paść w poleceniu, by wykonać daną akcję (zabezpieczenie przed pomyłką modelu).
    static let requiredCues: [String: [String]] = [
        "calendar_create_event": ["doda", "zapisz", "wpisz", "utworz", "stworz", "umow", "zaplanuj", "wstaw", "zarezerwuj", "dopisz", "nowe", "nowy", "ustaw"],
        "reminder_create": ["przypom", "doda", "zapisz", "utworz", "ustaw"],
        "alarm_set": ["budzik", "obudz", "zbudz", "alarm", "nastaw", "ustaw"],
        "timer_start": ["minutnik", "timer", "odlicz", "nastaw", "ustaw", "stoper"],
        "alarm_cancel": ["odwolaj", "usun", "wylacz", "anuluj", "skasuj", "zatrzymaj"],
        "message_send": ["napisz", "wyslij", "sms", "wiadomosc", "odpisz", "przeslij", "esemes"],
        "phone_call": ["zadzwon", "polacz", "dzwon", "wybierz", "zadzwonic"],
        "note_create": ["zanotuj", "notat", "zapisz", "zapamietaj"],
        "note_append": ["dopisz", "doda"],
        "workout": ["trening", "cwicz", "bieg", "spacer", "rower", "plywan", "joga", "silown"],
        "maps_navigate": ["prowadz", "nawig", "trasa", "trase", "dojazd", "dojechac", "dojsc", "zaprowadz", "jedziemy", "jedz"],
        "app_open": ["otworz", "uruchom", "wlacz", "pokaz", "odpal"],
        "shortcut_run": ["skrot", "uruchom", "wykonaj", "odpal"],
    ]

    static func hasCue(_ transcript: String, for tool: String) -> Bool {
        guard let cues = requiredCues[tool] else { return true }
        let words = TextNormalizer.words(transcript)
        return words.contains { word in cues.contains { word.hasPrefix($0) } }
    }

    // MARK: Pola → argumenty narzędzia

    static func route(_ fields: CommandFields, transcript: String, now: Date = .now, calendar: Calendar = .current) -> Route {
        let tool = fields.tool
        if tool == delegateTool { return .delegate("model lokalny przekazał polecenie do Claude") }
        guard tools.contains(where: { $0.name == tool }) else { return .delegate("nieznane narzędzie \(tool)") }

        if isQuestion(transcript), mutatingTools.contains(tool) {
            return .delegate("pytanie nie może wykonać akcji \(tool)")
        }
        if !hasCue(transcript, for: tool) {
            return .delegate("w poleceniu brak słowa pasującego do akcji \(tool)")
        }

        let parsed = PolishTimeParser.parse(transcript)
        let words = TextNormalizer.words(transcript)
        func dateTime() -> Date? {
            PolishTimeParser.resolveDateTime(parsed: parsed, modelDay: fields.day, modelHour: fields.hour,
                                             modelMinute: fields.minute, now: now, calendar: calendar)
        }
        func day() -> PolishTimeParser.Day? { parsed.day ?? fields.day.flatMap(PolishTimeParser.dayFromModel) }

        var args: [String: JSONValue] = [:]
        switch tool {
        case "calendar_agenda":
            let start = PolishTimeParser.date(for: day() ?? .relative(0), now: now, calendar: calendar)
            args["start"] = .string(DateParsing.iso(start, timeZone: calendar.timeZone))
            args["end"] = .string(DateParsing.iso(calendar.date(byAdding: .day, value: 1, to: start)!, timeZone: calendar.timeZone))

        case "calendar_create_event":
            guard let title = fields.title ?? fields.text else { return .delegate("brak tytułu wydarzenia") }
            args["title"] = .string(capitalized(title))
            if let start = dateTime() {
                args["start"] = .string(DateParsing.iso(start, timeZone: calendar.timeZone))
            } else if let day = day() {
                args["start"] = .string(DateParsing.iso(PolishTimeParser.date(for: day, now: now, calendar: calendar), timeZone: calendar.timeZone))
                args["all_day"] = true
            } else {
                return .delegate("brak terminu wydarzenia")
            }

        case "reminder_create":
            guard let title = fields.title ?? fields.text else { return .delegate("brak treści przypomnienia") }
            args["title"] = .string(capitalized(title))
            if let due = dateTime() { args["due"] = .string(DateParsing.iso(due, timeZone: calendar.timeZone)) }

        case "alarm_set":
            if fields.option == "daily" || words.contains("codziennie") {
                let time = parsed.time ?? fields.hour.map { PolishTimeParser.TimeOfDay(hour: $0, minute: fields.minute ?? 0) }
                guard let time else { return .delegate("brak godziny budzika") }
                args["daily_time"] = .string(String(format: "%02d:%02d", time.hour, time.minute))
            } else {
                guard var date = dateTime() else { return .delegate("brak godziny budzika") }
                if date <= now, day() == nil { date = calendar.date(byAdding: .day, value: 1, to: date)! }
                args["time"] = .string(DateParsing.iso(date, timeZone: calendar.timeZone))
            }
            if let title = fields.title { args["label"] = .string(title) }

        case "timer_start":
            guard let seconds = parsed.durationSeconds ?? fields.durationSeconds else { return .delegate("brak czasu minutnika") }
            args["seconds"] = .number(Double(seconds))
            if let title = fields.title, !title.lowercased().contains("minutnik") { args["label"] = .string(title) }

        case "alarm_cancel":
            if let title = fields.title { args["match"] = .string(title) }

        case "music_control":
            guard let option = fields.option else { return .delegate("brak akcji muzyki") }
            args["action"] = .string(option)

        case "music_play":
            guard let query = fields.title ?? fields.text else { return .delegate("brak tego, co włączyć") }
            args["query"] = .string(query)
            if let option = fields.option { args["kind"] = .string(option) }

        case "phone_call":
            guard let person = fields.person ?? fields.title else { return .delegate("brak osoby") }
            args["contact_name"] = .string(person)
            if fields.option == "facetime" { args["kind"] = "facetime" }

        case "message_send":
            guard let person = fields.person, let text = fields.text else { return .delegate("brak odbiorcy albo treści") }
            args["contact_name"] = .string(person)
            args["text"] = .string(text)
            if let option = fields.option { args["channel"] = .string(option) }

        case "note_create":
            guard let body = fields.text ?? fields.title else { return .delegate("brak treści notatki") }
            args["body"] = .string(body)
            args["title"] = .string(capitalized(fields.title ?? body.split(separator: " ").prefix(4).joined(separator: " ")))

        case "note_append":
            guard let title = fields.title, let text = fields.text else { return .delegate("brak notatki albo tekstu") }
            args["title"] = .string(title)
            args["text"] = .string(text)

        case "note_read":
            if let title = fields.title { args["title"] = .string(title) }

        case "maps_navigate":
            guard let destination = fields.title ?? fields.text else { return .delegate("brak celu") }
            args["destination"] = .string(destination)
            if let option = fields.option { args["mode"] = .string(option) }

        case "contact_find":
            guard let person = fields.person ?? fields.title else { return .delegate("brak osoby") }
            args["name"] = .string(person)
            if let option = fields.option { args["field"] = .string(option) }

        case "health_read":
            args["metrics"] = .array([.string(healthMetric(option: fields.option, words: words))])
            if case .relative(-1)? = day() { args["period"] = "yesterday" }
            if words.contains(where: { $0.hasPrefix("tydzien") || $0.hasPrefix("tygodni") }) { args["period"] = "week" }

        case "workout":
            let action = fields.option.flatMap { ["start", "stop", "status"].contains($0) ? $0 : nil }
                ?? (words.contains { ["zakoncz", "skoncz", "stop", "koniec", "zatrzymaj"].contains($0) } ? "stop" : "start")
            args["action"] = .string(action)
            if action == "start" { args["activity"] = .string(workoutActivity(words: words)) }

        case "app_open":
            guard let name = fields.title else { return .delegate("brak nazwy aplikacji") }
            args["app_name"] = .string(name)

        case "shortcut_run":
            guard let name = fields.title else { return .delegate("brak nazwy skrótu") }
            args["shortcut_name"] = .string(name)

        default:
            return .delegate("nieobsługiwane narzędzie \(tool)")
        }
        return .run(LocalDecision(tool: tool, args: .object(args)))
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + String(text.dropFirst())
    }

    private static func healthMetric(option: String?, words: [String]) -> String {
        if let option, ["steps", "heart_rate", "calories", "distance"].contains(option) { return option }
        if words.contains(where: { $0.hasPrefix("puls") || $0.hasPrefix("tetn") }) { return "heart_rate" }
        if words.contains(where: { $0.hasPrefix("kalori") || $0.hasPrefix("spalil") }) { return "calories" }
        if words.contains(where: { $0.hasPrefix("kilometr") || $0.hasPrefix("dystans") || $0.hasPrefix("przesz") }) { return "distance" }
        return "steps"
    }

    private static func workoutActivity(words: [String]) -> String {
        let map: [(String, String)] = [("bieg", "running"), ("spacer", "walking"), ("rower", "cycling"), ("silown", "strength"),
                                       ("joga", "yoga"), ("jog", "yoga"), ("plywan", "swimming"), ("interwal", "hiit")]
        return map.first { stem, _ in words.contains { $0.hasPrefix(stem) } }?.1 ?? "other"
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
            let title = args["title"]?.stringValue ?? "wydarzenie"
            if let start = args["start"]?.stringValue.flatMap({ DateParsing.parse($0) }) {
                let when = args["all_day"]?.boolValue == true
                    ? DateParsing.spoken(start).components(separatedBy: ", godz.").first ?? ""
                    : DateParsing.spoken(start)
                return "Zapisane w kalendarzu: \(title), \(when)."
            }
            return "Zapisane w kalendarzu."
        case "maps_navigate": return "Prowadzę do: \(args["destination"]?.stringValue ?? "celu")."
        case "workout":
            return args["action"]?.stringValue == "start" ? "Rozpoczynam trening." : output.modelText
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
