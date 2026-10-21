import Foundation

/// Model podaje daty jako ISO 8601 w czasie lokalnym („2026-10-22T09:00:00”) – sam rozwiązuje
/// wyrażenia typu „w przyszły wtorek”, „za dwie godziny”, „jutro rano” na podstawie bieżącej daty
/// przekazywanej w każdym poleceniu.
enum DateParsing {
    static func parse(_ text: String, timeZone: TimeZone = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        let withZone = ISO8601DateFormatter()
        withZone.formatOptions = [.withInternetDateTime]
        if let date = withZone.date(from: trimmed) { return date }
        withZone.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withZone.date(from: trimmed) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// Format przekazywany modelowi (czas lokalny z przesunięciem strefy).
    static func iso(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// „wtorek, 22 października 2026, 09:00” – do mówienia i kontekstu.
    static func spoken(_ date: Date, includeDate: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.dateFormat = includeDate ? "EEEE, d MMMM, 'godz.' H:mm" : "H:mm"
        return formatter.string(from: date)
    }

    static func contextLine(now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        return "Teraz: \(formatter.string(from: now)) (\(iso(now)), strefa \(TimeZone.current.identifier))."
    }
}
