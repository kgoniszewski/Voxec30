import Testing
@testable import Janek

struct WakeWordDetectorTests {
    let detector = WakeWordDetector(sensitivity: .normal)

    @Test(arguments: [
        ("Hej Janek", ""),
        ("hej janek zadzwoń do mamy", "zadzwoń do mamy"),
        ("Hey Janek, nastaw minutnik na 10 minut", "nastaw minutnik na 10 minut"),
        ("ej janku która godzina", "która godzina"),
        ("Hejjanek włącz muzykę", "włącz muzykę"),
        ("hej ja nek gdzie jestem", "gdzie jestem"),
        ("hej jonek zapisz notatkę", "zapisz notatkę"),
    ])
    func detectsWakePhrase(transcript: String, command: String) {
        #expect(detector.detect(in: transcript) == WakeWordDetector.Match(command: command))
    }

    @Test(arguments: ["Janek poszedł do sklepu", "hej Marek", "dzień dobry", "hej", ""])
    func ignoresOtherSpeech(transcript: String) {
        #expect(detector.detect(in: transcript) == nil)
    }

    @Test func usesLastOccurrence() {
        let match = detector.detect(in: "hej janek stop hej janek zadzwoń do Ani")
        #expect(match?.command == "zadzwoń do Ani")
    }

    @Test func strictSensitivityRejectsTypos() {
        let strict = WakeWordDetector(sensitivity: .strict)
        #expect(strict.detect(in: "hej janeg") == nil)
        #expect(detector.detect(in: "hej janeg") != nil)
    }
}

struct TextNormalizerTests {
    @Test func foldsPolishCharacters() {
        #expect(TextNormalizer.normalize("Zażółć GĘŚLĄ jaźń!") == "zazolc gesla jazn")
    }

    @Test func levenshtein() {
        #expect(TextNormalizer.levenshtein("janek", "janek") == 0)
        #expect(TextNormalizer.levenshtein("janek", "janku") == 2)
        #expect(TextNormalizer.levenshtein("janek", "jonek") == 1)
    }

    @Test func stemsDeclinedNames() {
        #expect(TextNormalizer.stem("Ani") == TextNormalizer.stem("Ania"))
        #expect("tomek".hasPrefix(TextNormalizer.stem("Tomka")))
    }
}
