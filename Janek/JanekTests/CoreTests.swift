import Foundation
import Testing
@testable import Janek

struct DateParsingTests {
    let warsaw = TimeZone(identifier: "Europe/Warsaw")!

    @Test func parsesLocalTime() throws {
        let date = try #require(DateParsing.parse("2026-10-27T10:00:00", timeZone: warsaw))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = warsaw
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(parts == DateComponents(year: 2026, month: 10, day: 27, hour: 10, minute: 0))
    }

    @Test func parsesOffsetAndShortForms() {
        #expect(DateParsing.parse("2026-10-27T10:00:00+01:00") != nil)
        #expect(DateParsing.parse("2026-10-27T10:00") != nil)
        #expect(DateParsing.parse("2026-10-27") != nil)
        #expect(DateParsing.parse("jutro") == nil)
    }
}

struct PhoneFormattingTests {
    @Test func international() {
        #expect(PhoneFormatting.international("601 234 567") == "48601234567")
        #expect(PhoneFormatting.international("+48 601-234-567") == "48601234567")
        #expect(PhoneFormatting.international("0049 30 1234567") == "49301234567")
    }
}

struct AnthropicClientTests {
    @Test func buildsRequestWithCachingAndFallback() throws {
        let client = AnthropicClient(apiKey: "test-key")
        let request = try client.makeURLRequest(.init(
            model: .opus, effort: .low, system: "S", tools: [["name": "t"]],
            messages: [["role": "user", "content": "cześć"]]
        ))
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == AnthropicClient.fallbackBeta)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(body["model"] == "claude-opus-5-5")
        #expect(body["fallbacks"] == "default")
        #expect(body["output_config"]?["effort"] == "low")
        #expect(body["system"]?.arrayValue?.first?["cache_control"]?["type"] == "ephemeral")
        #expect(body["thinking"] == nil)
    }

    @Test func haikuHasNoFallback() throws {
        let request = try AnthropicClient(apiKey: "k").makeURLRequest(.init(
            model: .haiku, effort: .low, system: "S", tools: [], messages: []
        ))
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(body["fallbacks"] == nil)
        #expect(body["tools"] == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test func decodesToolUse() throws {
        let json = """
        {"id":"msg_1","model":"claude-opus-5-5","stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5},
         "content":[{"type":"thinking","thinking":"","signature":"abc"},{"type":"text","text":"Już dzwonię."},
                    {"type":"tool_use","id":"toolu_1","name":"phone_call","input":{"contact_name":"mama"}}]}
        """
        let response = try AnthropicClient.decode(Data(json.utf8))
        #expect(response.stopReason == "tool_use")
        #expect(response.text == "Już dzwonię.")
        #expect(response.toolUses.first?.name == "phone_call")
        #expect(response.toolUses.first?.input["contact_name"] == "mama")
        #expect(response.content.count == 3) // blok thinking zachowany do odesłania
    }
}
