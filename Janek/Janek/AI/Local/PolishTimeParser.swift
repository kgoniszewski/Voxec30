import Foundation

/// Deterministyczne rozpoznawanie polskich wyrażeń czasu w transkrypcji mowy.
///
/// Małe modele lokalne często mylą się przy zamianie słów na liczby („o dwudziestej pierwszej”
/// → 24:00), zwłaszcza gdy rozpoznawanie mowy zrobi literówkę („pierszwej”). Dlatego godziny,
/// dni i czasy trwania wyciągamy z tekstu kodem, a od modelu bierzemy tylko to, *co* zrobić.
enum PolishTimeParser {
    struct TimeOfDay: Equatable, Sendable {
        var hour: Int
        var minute: Int
    }

    enum Day: Equatable, Sendable {
        case relative(Int)                       // dziś = 0, jutro = 1, pojutrze = 2, wczoraj = -1
        case weekday(Int, next: Bool)            // 1 = niedziela … 7 = sobota (jak Calendar), „przyszły”
    }

    struct Result: Equatable, Sendable {
        var day: Day?
        var time: TimeOfDay?
        var durationSeconds: Int?
    }

    static func parse(_ text: String) -> Result {
        let words = TextNormalizer.words(text)
        return Result(day: day(in: words), time: time(in: words, original: text), durationSeconds: duration(in: words))
    }

    // MARK: Dni

    /// Nazwy dni dla `Day.weekday` (indeksy jak w `Calendar`: 1 = niedziela).
    static let weekdayForms: [Int: [String]] = [
        2: ["poniedzialek", "poniedzialku", "poniedzialkiem"],
        3: ["wtorek", "wtorku"],
        4: ["sroda", "srode", "srody", "srodzie"],
        5: ["czwartek", "czwartku"],
        6: ["piatek", "piatku"],
        7: ["sobota", "sobote", "soboty", "sobocie"],
        1: ["niedziela", "niedziele", "niedzieli"],
    ]

    static func day(in words: [String]) -> Day? {
        let next = words.contains { $0.hasPrefix("przysz") || $0 == "nastepny" || $0 == "nastepna" || $0 == "nastepnym" }
        for word in words {
            switch word {
            case "dzis", "dzisiaj", "dzisiejszy", "dzisiejsza": return .relative(0)
            case "jutro", "jutrzejszy", "jutrzejsza": return .relative(1)
            case "pojutrze": return .relative(2)
            case "wczoraj", "wczorajszy", "wczorajsza": return .relative(-1)
            default: break
            }
            if let weekday = weekdayForms.first(where: { $0.value.contains(word) })?.key {
                return .weekday(weekday, next: next)
            }
        }
        return nil
    }

    /// Konkretna data dla dnia (o północy), licząc od `now`.
    static func date(for day: Day, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        switch day {
        case .relative(let offset):
            return calendar.date(byAdding: .day, value: offset, to: today)!
        case .weekday(let weekday, let next):
            // Tydzień od poniedziałku (0) do niedzieli (6), jak w Polsce.
            let mondayBased = { (calendarWeekday: Int) in (calendarWeekday + 5) % 7 }
            let current = mondayBased(calendar.component(.weekday, from: today))
            let target = mondayBased(weekday)
            var offset: Int
            if target > current {
                offset = target - current
                // „w przyszły wtorek” – gdy ten dzień jest jeszcze w bieżącym tygodniu, chodzi o następny tydzień.
                if next { offset += 7 }
            } else {
                offset = target - current + 7 // „w środę” powiedziane w środę = za tydzień
            }
            return calendar.date(byAdding: .day, value: offset, to: today)!
        }
    }

    // MARK: Godziny

    /// Formy liczebników porządkowych godzin (rodzaj żeński: „pierwsza”, „o pierwszej”).
    static let hourForms: [(Int, [String])] = [
        (1, ["pierwsza", "pierwszej"]), (2, ["druga", "drugiej"]), (3, ["trzecia", "trzeciej"]),
        (4, ["czwarta", "czwartej"]), (5, ["piata", "piatej"]), (6, ["szosta", "szostej"]),
        (7, ["siodma", "siodmej"]), (8, ["osma", "osmej"]), (9, ["dziewiata", "dziewiatej"]),
        (10, ["dziesiata", "dziesiatej"]), (11, ["jedenasta", "jedenastej"]), (12, ["dwunasta", "dwunastej"]),
        (13, ["trzynasta", "trzynastej"]), (14, ["czternasta", "czternastej"]), (15, ["pietnasta", "pietnastej"]),
        (16, ["szesnasta", "szesnastej"]), (17, ["siedemnasta", "siedemnastej"]), (18, ["osiemnasta", "osiemnastej"]),
        (19, ["dziewietnasta", "dziewietnastej"]), (20, ["dwudziesta", "dwudziestej"]),
    ]

    /// Słowa, które wyglądają podobnie do liczebników godzin, ale nimi nie są.
    static let notHours: Set<String> = ["czwartek", "czwartku", "piatek", "piatku", "sobota", "sobote", "drugi"]

    /// Liczebnik godziny z tolerancją na literówki rozpoznawania mowy.
    static func hourOrdinal(_ word: String) -> Int? {
        guard !notHours.contains(word), !word.hasSuffix("ego"), !word.hasSuffix("emu"), word.count >= 4 else { return nil }
        for (hour, forms) in hourForms where forms.contains(word) { return hour }
        guard word.count >= 7 else { return nil }
        let tolerance = word.count >= 9 ? 2 : 1
        var best: (hour: Int, distance: Int)?
        for (hour, forms) in hourForms {
            for form in forms where abs(form.count - word.count) <= tolerance {
                let distance = TextNormalizer.levenshtein(word, form)
                if distance <= tolerance, distance < (best?.distance ?? .max) { best = (hour, distance) }
            }
        }
        return best?.hour
    }

    static let cardinals: [String: Int] = [
        "zero": 0, "jeden": 1, "jedna": 1, "jedno": 1, "dwa": 2, "dwie": 2, "trzy": 3, "cztery": 4,
        "piec": 5, "szesc": 6, "siedem": 7, "osiem": 8, "dziewiec": 9, "dziesiec": 10, "jedenascie": 11,
        "dwanascie": 12, "trzynascie": 13, "czternascie": 14, "pietnascie": 15, "szesnascie": 16,
        "siedemnascie": 17, "osiemnascie": 18, "dziewietnascie": 19, "dwadziescia": 20, "trzydziesci": 30,
        "czterdziesci": 40, "piecdziesiat": 50, "szescdziesiat": 60, "siedemdziesiat": 70,
        "osiemdziesiat": 80, "dziewiecdziesiat": 90, "sto": 100,
    ]

    /// Liczba zapisana słowami lub cyframi od pozycji `index` (np. „czterdzieści pięć”). Zwraca liczbę i liczbę zużytych słów.
    static func cardinal(in words: [String], at index: Int) -> (value: Int, length: Int)? {
        guard index < words.count else { return nil }
        if let value = Int(words[index]) { return (value, 1) }
        guard let first = cardinals[words[index]] else { return nil }
        if first >= 20, first % 10 == 0, first < 100, index + 1 < words.count,
           let unit = cardinals[words[index + 1]], (1...9).contains(unit) {
            return (first + unit, 2)
        }
        return (first, 1)
    }

    static func time(in words: [String], original: String) -> TimeOfDay? {
        var result: TimeOfDay?

        // 1) Zapis cyfrowy: „21:30”, „21.30”, „o 21”, „o 21 30”.
        if let match = original.range(of: #"\b([01]?\d|2[0-4])[:.]([0-5]\d)\b"#, options: .regularExpression) {
            let parts = original[match].split(whereSeparator: { $0 == ":" || $0 == "." }).compactMap { Int($0) }
            if parts.count == 2 { result = TimeOfDay(hour: parts[0] % 24, minute: parts[1]) }
        }
        if result == nil {
            for (index, word) in words.enumerated() where word == "o" || word == "na" || word == "godzina" || word == "godz" {
                guard index + 1 < words.count, let hour = Int(words[index + 1]), (0...24).contains(hour) else { continue }
                var minute = 0
                if index + 2 < words.count, let value = Int(words[index + 2]), (0...59).contains(value), words[index + 2].count == 2 {
                    minute = value
                }
                result = TimeOfDay(hour: hour % 24, minute: minute)
                break
            }
        }

        // 2) Słownie: „o dwudziestej pierwszej trzydzieści”, „wpół do ósmej”, „kwadrans po ósmej”, „za kwadrans ósma”.
        if result == nil {
            for (index, word) in words.enumerated() {
                guard var hour = hourOrdinal(word) else { continue }
                var consumed = 1
                if hour == 20, index + 1 < words.count, let unit = hourOrdinal(words[index + 1]), (1...4).contains(unit) {
                    hour += unit
                    consumed = 2
                }
                var minute = 0
                let previous = index >= 1 ? words[index - 1] : ""
                let beforePrevious = index >= 2 ? words[index - 2] : ""
                if previous == "do" && (beforePrevious == "wpol" || beforePrevious == "pol") {
                    hour -= 1
                    minute = 30
                } else if previous == "po" && beforePrevious == "kwadrans" {
                    minute = 15
                } else if previous == "kwadrans" && beforePrevious == "za" {
                    hour -= 1
                    minute = 45
                } else if let value = cardinal(in: words, at: index + consumed), (0...59).contains(value.value),
                          !isUnit(words, index + consumed + value.length) {
                    minute = value.value
                }
                result = TimeOfDay(hour: (hour + 24) % 24, minute: minute)
                break
            }
        }

        if result == nil {
            if words.contains("poludnie") || containsPhrase(words, ["w", "poludnie"]) { result = TimeOfDay(hour: 12, minute: 0) }
            if words.contains("polnocy") || words.contains("polnoc") { result = TimeOfDay(hour: 0, minute: 0) }
        }

        // 3) Pora dnia: „o ósmej wieczorem” = 20:00.
        if var time = result, (1...11).contains(time.hour) {
            let evening = words.contains("wieczorem") || words.contains("wieczor") || containsPhrase(words, ["po", "poludniu"])
                || words.contains("popoludniu") || containsPhrase(words, ["w", "nocy"]) && time.hour >= 9
            if evening { time.hour += 12 }
            result = time
        }
        return result
    }

    private static func isUnit(_ words: [String], _ index: Int) -> Bool {
        guard index < words.count else { return false }
        return ["minut", "minuty", "minute", "sekund", "sekundy", "godzin", "godziny", "godzine", "dni", "razy"].contains(words[index])
    }

    private static func containsPhrase(_ words: [String], _ phrase: [String]) -> Bool {
        guard words.count >= phrase.count else { return false }
        for start in 0...(words.count - phrase.count) where Array(words[start..<start + phrase.count]) == phrase { return true }
        return false
    }

    // MARK: Czas trwania (minutnik)

    static func duration(in words: [String]) -> Int? {
        var total = 0
        var found = false
        var index = 0
        while index < words.count {
            let word = words[index]
            // Stałe wyrażenia
            if word == "pol" || word == "wpol", index + 1 < words.count, words[index + 1].hasPrefix("godzin") {
                total += 1800; found = true; index += 2; continue
            }
            if word == "poltorej" || word == "poltora", index + 1 < words.count {
                if words[index + 1].hasPrefix("godzin") { total += 5400; found = true; index += 2; continue }
                if words[index + 1].hasPrefix("minut") { total += 90; found = true; index += 2; continue }
            }
            if word == "kwadrans" && (index == 0 || words[index - 1] != "za") && (index + 1 >= words.count || words[index + 1] != "po") {
                total += 900; found = true; index += 1; continue
            }
            // Liczba + jednostka
            if let number = cardinal(in: words, at: index), index + number.length < words.count,
               let unit = unitSeconds(words[index + number.length]) {
                total += number.value * unit; found = true; index += number.length + 1; continue
            }
            // Sama jednostka w bierniku: „na minutę”, „na godzinę”
            if ["minute", "godzine", "sekunde"].contains(word), index >= 1, ["na", "za", "i"].contains(words[index - 1]) {
                total += unitSeconds(word) ?? 0; found = true
            }
            index += 1
        }
        return found && total > 0 ? total : nil
    }

    private static func unitSeconds(_ word: String) -> Int? {
        if word.hasPrefix("sekund") { return 1 }
        if word.hasPrefix("minut") || word == "min" { return 60 }
        if word.hasPrefix("godzin") || word == "h" { return 3600 }
        return nil
    }

    // MARK: Łączenie z odpowiedzią modelu

    /// Data i godzina: z tekstu (pierwszeństwo), a gdy brak – z pól modelu. `nil`, gdy nie podano godziny.
    static func resolveDateTime(parsed: Result, modelDay: String?, modelHour: Int?, modelMinute: Int?,
                                now: Date = .now, calendar: Calendar = .current) -> Date? {
        let time = parsed.time ?? modelHour.map { TimeOfDay(hour: $0 % 24, minute: modelMinute ?? 0) }
        guard let time else { return nil }
        let day = parsed.day ?? modelDay.flatMap(dayFromModel)
        let base = date(for: day ?? .relative(0), now: now, calendar: calendar)
        return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: base)
    }

    /// Dzień w postaci zwróconej przez model („dziś”, „jutro”, „wtorek”…).
    static func dayFromModel(_ text: String) -> Day? {
        day(in: TextNormalizer.words(text))
    }
}
