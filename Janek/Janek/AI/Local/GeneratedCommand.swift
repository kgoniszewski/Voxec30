import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// Struktura, którą model (Apple Intelligence albo MLX przez `MLXFoundationModels`) musi wygenerować.
/// Generowanie jest ograniczone gramatyką: `tool`, `day` i `option` mogą przyjąć tylko podane
/// wartości, a liczby tylko podane zakresy – model nie może zwrócić niepoprawnej struktury.
/// Wartości „brak”, pusty tekst i -1 oznaczają brak pola.
@Generable(description: "Polecenie użytkownika rozłożone na pola")
struct GeneratedCommand {
    @Guide(description: "Co zrobić; claude, gdy polecenie nie pasuje do żadnej akcji lub jest pytaniem o wiedzę", .anyOf([
        "calendar_agenda", "calendar_create_event", "reminder_create", "alarm_set", "timer_start", "alarm_cancel",
        "music_control", "music_play", "phone_call", "message_send", "note_create", "note_append", "note_read",
        "maps_navigate", "contact_find", "health_read", "workout", "app_open", "shortcut_run", "claude",
    ]))
    var tool: String

    @Guide(description: "Tytuł wydarzenia/przypomnienia/notatki, nazwa aplikacji, skrótu, miejsca docelowego albo muzyki; pusty, gdy nie dotyczy")
    var title: String

    @Guide(description: "Treść wiadomości lub notatki, tekst do dopisania; pusty, gdy nie dotyczy")
    var text: String

    @Guide(description: "Osoba w mianowniku, np. mama, Ania, Tomek; pusty, gdy nie dotyczy")
    var person: String

    @Guide(description: "Dzień", .anyOf([
        "brak", "dziś", "jutro", "pojutrze", "wczoraj", "poniedziałek", "wtorek", "środa", "czwartek", "piątek", "sobota", "niedziela",
    ]))
    var day: String

    @Guide(description: "Godzina 0–23; -1, gdy nie podano", .range(-1...23))
    var hour: Int

    @Guide(description: "Minuty 0–59; -1, gdy nie podano", .range(-1...59))
    var minute: Int

    @Guide(description: "Czas trwania minutnika w sekundach; 0, gdy nie dotyczy", .range(0...86_400))
    var durationSeconds: Int

    @Guide(description: "Wariant akcji; brak, gdy nie dotyczy", .anyOf([
        "brak", "play", "pause", "next", "previous", "shuffle_on", "shuffle_off", "now_playing",
        "artist", "song", "album", "playlist", "phone", "facetime", "sms", "whatsapp", "telegram", "signal",
        "driving", "walking", "transit", "cycling", "email", "address", "steps", "heart_rate", "calories",
        "distance", "start", "stop", "status", "daily",
    ]))
    var option: String

    var fields: CommandFields {
        CommandFields(tool: tool, title: title, text: text, person: person, day: day,
                      hour: hour, minute: minute, durationSeconds: durationSeconds, option: option)
    }
}
#endif
