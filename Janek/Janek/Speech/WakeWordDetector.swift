import Foundation

/// Wykrywa frazę „Hej Janek” w transkrypcji (tolerując błędy rozpoznawania: „hey janek”,
/// „hej janku”, „ej janek”, „hejjanek”, „hej ja nek”…) i zwraca polecenie wypowiedziane po niej.
struct WakeWordDetector: Sendable {
    struct Match: Equatable, Sendable {
        /// Tekst polecenia po frazie (w oryginalnej pisowni rozpoznawania).
        var command: String
    }

    var name = "janek"
    var greetings: Set<String> = ["hej", "hey", "hei", "hay", "ej", "hejo", "hejka", "heja", "he", "ehj", "halo", "czesc"]
    /// Formy imienia, które zawsze akceptujemy (odmiana i typowe pomyłki rozpoznawania).
    var nameForms: Set<String> = ["janek", "janku", "janka", "jankiem", "janeczku", "jonek", "janik", "janet", "janeck"]
    var maxNameDistance = 1

    init(sensitivity: WakeSensitivity = .normal) {
        maxNameDistance = sensitivity.rawValue
    }

    func isName(_ word: String) -> Bool {
        nameForms.contains(word) || (word.count >= 4 && TextNormalizer.levenshtein(word, name) <= maxNameDistance)
    }

    /// Szuka OSTATNIEGO wystąpienia frazy, by polecenie zawsze dotyczyło najnowszej wypowiedzi.
    func detect(in transcript: String) -> Match? {
        let original = transcript.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let normalized = original.map { TextNormalizer.normalize($0).replacingOccurrences(of: " ", with: "") }
        guard !normalized.isEmpty else { return nil }

        var endIndex: Int? // indeks ostatniego słowa frazy
        for i in stride(from: normalized.count - 1, through: 0, by: -1) {
            let word = normalized[i]
            // „hejjanek”, „heyjanek”
            if greetings.contains(where: { $0.count >= 2 && word.hasPrefix($0) && isName(String(word.dropFirst($0.count))) }) {
                endIndex = i; break
            }
            guard i + 1 < normalized.count, greetings.contains(word) else { continue }
            if isName(normalized[i + 1]) { endIndex = i + 1; break }
            // „hej ja nek”
            if i + 2 < normalized.count, isName(normalized[i + 1] + normalized[i + 2]) { endIndex = i + 2; break }
        }
        guard let endIndex else { return nil }
        let command = original[(endIndex + 1)...].joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        return Match(command: command)
    }
}
