import Foundation

enum TextNormalizer {
    /// Małe litery, bez polskich znaków diakrytycznych i interpunkcji, pojedyncze spacje.
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "ł", with: "l")
        let folded = lowered.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pl_PL"))
        let cleaned = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    static func words(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    /// Odległość Levenshteina (liczba wstawień/usunięć/zamian).
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Bardzo prosty „stemmer” dla polskiej odmiany imion: „Ani” → „an”, „Ania” → „an”, „Kasi” → „kas”.
    static func stem(_ word: String) -> String {
        let normalized = normalize(word)
        guard normalized.count > 3 else { return normalized }
        let suffixes = ["owie", "iem", "ego", "emu", "owi", "ami", "om", "ie", "ia", "iu", "ki", "ka", "ku", "ce", "a", "i", "u", "e", "y", "o", "ę", "ą"]
        for suffix in suffixes where normalized.hasSuffix(suffix) && normalized.count - suffix.count >= 3 {
            return String(normalized.dropLast(suffix.count))
        }
        return normalized
    }
}
