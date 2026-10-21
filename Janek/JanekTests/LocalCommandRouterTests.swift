import Foundation
import Testing
@testable import Janek

struct LocalCommandRouterTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return calendar
    }
    /// Środa, 21 października 2026, 14:05.
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 14, minute: 5))! }

    func start(_ route: LocalCommandRouter.Route) -> DateComponents? {
        guard case .run(let decision) = route,
              let iso = (decision.args["start"] ?? decision.args["time"] ?? decision.args["due"])?.stringValue,
              let date = DateParsing.parse(iso) else { return nil }
        return calendar.dateComponents([.day, .hour, .minute], from: date)
    }

    // MARK: Zgłoszone błędy

    @Test func eventTimeComesFromTranscriptNotFromModel() {
        let text = "Dodaj w kalendarzu dziś wydarzenie mecz o dwudziestej pierszwej"
        // Model pomylił godzinę (24:00 → 0) i dzień – kod bierze je z transkrypcji.
        let fields = CommandFields(tool: "calendar_create_event", title: "mecz", day: "jutro", hour: 0, minute: 0)
        let route = LocalCommandRouter.route(fields, transcript: text, now: now, calendar: calendar)
        #expect(start(route) == DateComponents(day: 21, hour: 21, minute: 0))
        if case .run(let decision) = route { #expect(decision.args["title"] == "Mecz") }
    }

    @Test func questionAboutCalendarReadsAgendaWithoutModel() throws {
        let text = "Czy mam dziś jakieś wydarzenia w Kalendarzu"
        let route = try #require(LocalCommandRouter.preRoute(text, now: now, calendar: calendar))
        guard case .run(let decision) = route else { Issue.record("oczekiwano calendar_agenda"); return }
        #expect(decision.tool == "calendar_agenda")
        #expect(decision.args["start"]?.stringValue?.hasPrefix("2026-10-21T00:00:00") == true)
    }

    @Test func questionCanNeverCreateEvent() {
        let fields = CommandFields(tool: "calendar_create_event", title: "wydarzenie", day: "dziś", hour: 12)
        let route = LocalCommandRouter.route(fields, transcript: "Czy mam dziś jakieś wydarzenia", now: now, calendar: calendar)
        #expect(route != .run(LocalDecision(tool: "calendar_create_event", args: [:])))
        if case .run = route { Issue.record("pytanie nie może tworzyć wydarzeń") }
    }

    // MARK: Zabezpieczenia

    @Test func actionsRequireMatchingVerb() {
        let fields = CommandFields(tool: "message_send", text: "hej", person: "Ania")
        if case .run = LocalCommandRouter.route(fields, transcript: "Ania jest fajna", now: now, calendar: calendar) {
            Issue.record("bez „napisz/wyślij” nie wysyłamy wiadomości")
        }
    }

    @Test func politeQuestionIsACommand() {
        #expect(!LocalCommandRouter.isQuestion("Czy możesz zadzwonić do mamy?"))
        #expect(LocalCommandRouter.isQuestion("O której mam dentystę"))
        #expect(LocalCommandRouter.isQuestion("co mam jutro"))
        #expect(!LocalCommandRouter.isQuestion("Zadzwoń do mamy"))
    }

    @Test func delegateAndUnknownTools() {
        #expect(LocalCommandRouter.route(CommandFields(tool: "claude"), transcript: "x") != .run(LocalDecision(tool: "claude", args: [:])))
        if case .run = LocalCommandRouter.route(CommandFields(tool: "calendar_cancel_event"), transcript: "odwołaj") {
            Issue.record("nieobsługiwane narzędzie")
        }
    }

    // MARK: Mapowanie pól

    @Test func timerUsesParsedDuration() {
        let route = LocalCommandRouter.route(CommandFields(tool: "timer_start", durationSeconds: 60),
                                             transcript: "Nastaw minutnik na dwanaście minut", now: now, calendar: calendar)
        guard case .run(let decision) = route else { Issue.record("oczekiwano minutnika"); return }
        #expect(decision.args["seconds"] == 720)
    }

    @Test func alarmForPastTimeMovesToTomorrow() {
        let route = LocalCommandRouter.route(CommandFields(tool: "alarm_set"),
                                             transcript: "Ustaw budzik na siódmą", now: now, calendar: calendar)
        #expect(start(route) == DateComponents(day: 22, hour: 7, minute: 0))
    }

    @Test func alarmHalfPast() {
        let route = LocalCommandRouter.route(CommandFields(tool: "alarm_set"),
                                             transcript: "Obudź mnie jutro o wpół do siódmej", now: now, calendar: calendar)
        #expect(start(route) == DateComponents(day: 22, hour: 6, minute: 30))
    }

    @Test func eventWithoutTimeIsAllDay() {
        let route = LocalCommandRouter.route(CommandFields(tool: "calendar_create_event", title: "urodziny Ani"),
                                             transcript: "Dodaj w piątek urodziny Ani", now: now, calendar: calendar)
        guard case .run(let decision) = route else { Issue.record("oczekiwano wydarzenia"); return }
        #expect(decision.args["all_day"] == true)
        #expect(start(route)?.day == 23)
    }

    @Test func emptyAndPlaceholderFieldsAreIgnored() {
        let fields = CommandFields(tool: "phone_call", title: "", text: "brak", person: "mama", day: "brak", hour: -1, minute: -1, durationSeconds: 0, option: "brak")
        #expect(fields.title == nil && fields.text == nil && fields.day == nil && fields.hour == nil && fields.option == nil)
        guard case .run(let decision) = LocalCommandRouter.route(fields, transcript: "zadzwoń do mamy") else {
            Issue.record("oczekiwano połączenia"); return
        }
        #expect(decision.args == ["contact_name": "mama"])
    }

    // MARK: Odpowiedź tekstowa

    @Test func parsesTextJSON() {
        let text = "<think>\n</think>\n```json\n{\"tool\": \"timer_start\", \"duration_seconds\": \"300\", \"title\": \"\"}\n```"
        #expect(LocalCommandRouter.parse(text) == CommandFields(tool: "timer_start", durationSeconds: 300))
        #expect(LocalCommandRouter.parse("Nie wiem") == nil)
        #expect(LocalCommandRouter.firstJSONObject(in: #"{"a":"{ }"} x"#) == #"{"a":"{ }"}"#)
    }

    @Test func polishPlurals() {
        #expect(LocalCommandRouter.spokenDuration(60) == "1 minutę")
        #expect(LocalCommandRouter.spokenDuration(180) == "3 minuty")
        #expect(LocalCommandRouter.spokenDuration(720) == "12 minut")
        #expect(LocalCommandRouter.spokenDuration(1320) == "22 minuty")
    }

    @Test func instructionsListEveryTool() {
        let text = LocalCommandRouter.instructions(now: now, calendar: calendar)
        for tool in LocalCommandRouter.toolNames { #expect(text.contains(tool)) }
        #expect(text.contains("środa, godzina 14:05"))
    }
}

struct PolishTimeParserTests {
    func time(_ text: String) -> String {
        PolishTimeParser.parse(text).time.map { String(format: "%02d:%02d", $0.hour, $0.minute) } ?? "-"
    }

    @Test(arguments: [
        ("mecz o dwudziestej pierszwej", "21:00"), ("o dwudziestej drugiej trzydzieści", "22:30"),
        ("o ósmej wieczorem", "20:00"), ("o ósmej rano", "08:00"), ("wpół do ósmej", "07:30"),
        ("kwadrans po dziewiątej", "09:15"), ("za kwadrans dziesiąta", "09:45"), ("o 21:30", "21:30"),
        ("o 21", "21:00"), ("o trzeciej po południu", "15:00"), ("w południe", "12:00"),
        ("w czwartek o dziesiątej", "10:00"), ("dwudziestego pierwszego października", "-"),
    ])
    func times(text: String, expected: String) {
        #expect(time(text) == expected)
    }

    @Test(arguments: [
        ("na dwanaście minut", 720), ("na pół godziny", 1800), ("na półtorej godziny", 5400),
        ("na godzinę i dwadzieścia minut", 4800), ("na minutę", 60), ("na czterdzieści pięć sekund", 45),
    ])
    func durations(text: String, seconds: Int) {
        #expect(PolishTimeParser.parse(text).durationSeconds == seconds)
    }
}
