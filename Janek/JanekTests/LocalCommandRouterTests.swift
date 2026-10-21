import Foundation
import Testing
@testable import Janek

struct LocalCommandRouterTests {
    @Test func parsesPlainJSON() {
        let decision = LocalCommandRouter.parse(#"{"tool":"timer_start","args":{"seconds":600}}"#)
        #expect(decision == LocalDecision(tool: "timer_start", args: ["seconds": 600]))
    }

    @Test func parsesJSONWrappedInThinkingAndCodeFence() {
        let text = "<think>\nUżytkownik chce minutnik.\n</think>\n```json\n{\"tool\": \"phone_call\", \"args\": {\"contact_name\": \"mama\"}}\n```"
        #expect(LocalCommandRouter.parse(text)?.tool == "phone_call")
    }

    @Test func handlesBracesInsideStrings() {
        let text = #"{"tool":"note_create","args":{"title":"Kod","body":"użyj { i } ostrożnie"}} trailing"#
        #expect(LocalCommandRouter.parse(text)?.args["body"] == "użyj { i } ostrożnie")
    }

    @Test func rejectsGarbage() {
        #expect(LocalCommandRouter.parse("Nie wiem, o co chodzi.") == nil)
        #expect(LocalCommandRouter.parse(#"{"args":{}}"#) == nil)
    }

    @Test func parsesGuidedGenerationArguments() {
        #expect(LocalCommandRouter.parse(tool: "claude", argumentsJSON: "")?.isDelegate == true)
        #expect(LocalCommandRouter.parse(tool: "music_play", argumentsJSON: #"{"query":"Sanah"}"#)?.args["query"] == "Sanah")
        #expect(LocalCommandRouter.parse(tool: "music_play", argumentsJSON: "query=Sanah") == nil)
    }

    @Test func validationRejectsUnknownToolsAndMissingArguments() {
        #expect(LocalCommandRouter.validate(LocalDecision(tool: "calendar_cancel_event", args: [:])) == nil)
        #expect(LocalCommandRouter.validate(LocalDecision(tool: "phone_call", args: ["contact_name": ""])) == nil)
        #expect(LocalCommandRouter.validate(LocalDecision(tool: "timer_start", args: ["seconds": 0])) == nil)
        #expect(LocalCommandRouter.validate(LocalDecision(tool: "music_control", args: ["action": "louder"])) == nil)
        #expect(LocalCommandRouter.validate(LocalDecision(tool: "alarm_set", args: ["time": "2001-01-01T08:00:00"])) == nil)
        #expect(LocalCommandRouter.validate(LocalDecision(tool: "calendar_create_event", args: ["title": "X", "start": "jutro"])) == nil)
    }

    @Test func validationNormalizesArguments() throws {
        let timer = try #require(LocalCommandRouter.validate(LocalDecision(tool: "timer_start", args: ["seconds": "300", "label": ""])))
        #expect(timer.args == ["seconds": 300])
        let health = try #require(LocalCommandRouter.validate(LocalDecision(tool: "health_read", args: ["metrics": "steps"])))
        #expect(health.args["metrics"] == ["steps"])
        #expect(LocalCommandRouter.validate(.delegate)?.isDelegate == true)
    }

    @Test func polishPlurals() {
        #expect(LocalCommandRouter.spokenDuration(60) == "1 minutę")
        #expect(LocalCommandRouter.spokenDuration(180) == "3 minuty")
        #expect(LocalCommandRouter.spokenDuration(720) == "12 minut")
        #expect(LocalCommandRouter.spokenDuration(1320) == "22 minuty")
        #expect(LocalCommandRouter.spokenDuration(5430) == "1 godzinę i 30 minut i 30 sekund")
    }

    @Test func confirmations() {
        let timer = LocalDecision(tool: "timer_start", args: ["seconds": 600])
        #expect(LocalCommandRouter.confirmation(for: timer, output: .ok("x")) == "Minutnik na 10 minut.")
        let health = LocalDecision(tool: "health_read", args: ["metrics": ["steps"]])
        #expect(LocalCommandRouter.confirmation(for: health, output: .privateReadout("Dziś: 5000 kroków.")) == "")
    }

    @Test func instructionsListEveryToolAndUpcomingDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 14, minute: 5))!
        let text = LocalCommandRouter.instructions(now: now, calendar: calendar)
        for spec in LocalCommandRouter.specs { #expect(text.contains(spec.name)) }
        #expect(text.contains("dziś (środa): 2026-10-21"))
        #expect(text.contains("jutro (czwartek): 2026-10-22"))
        #expect(text.contains("Teraz jest 14:05"))
    }
}
