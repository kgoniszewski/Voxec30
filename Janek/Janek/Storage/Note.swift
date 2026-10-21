import Foundation
import SwiftData

/// Notatka we własnej bazie Janka (SwiftData, tylko na urządzeniu).
@Model
final class Note {
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date

    init(title: String, body: String, createdAt: Date = .now) {
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

@MainActor
enum NotesDatabase {
    static let container: ModelContainer = {
        let configuration = ModelConfiguration("JanekNotes", isStoredInMemoryOnly: false, allowsSave: true, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: Note.self, configurations: configuration)
        } catch {
            fatalError("Nie można otworzyć bazy notatek: \(error)")
        }
    }()

    static var context: ModelContext { container.mainContext }

    static func all() throws -> [Note] {
        try context.fetch(FetchDescriptor<Note>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
    }

    /// Wyszukiwanie odporne na odmianę i brak polskich znaków.
    static func search(_ query: String) throws -> [Note] {
        let stems = query.split(separator: " ").map { TextNormalizer.stem(String($0)) }.filter { $0.count >= 2 }
        guard !stems.isEmpty else { return try all() }
        return try all()
            .map { note -> (Note, Int) in
                let haystack = TextNormalizer.normalize(note.title + " " + note.body)
                let titleText = TextNormalizer.normalize(note.title)
                let score = stems.reduce(0) { score, stem in
                    score + (titleText.contains(stem) ? 3 : 0) + (haystack.contains(stem) ? 1 : 0)
                }
                return (note, score)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}
