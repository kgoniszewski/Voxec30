import SwiftData
import SwiftUI

struct NotesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @State private var search = ""

    private var filtered: [Note] {
        guard !search.isEmpty else { return notes }
        let needle = TextNormalizer.normalize(search)
        return notes.filter { TextNormalizer.normalize($0.title + " " + $0.body).contains(needle) }
    }

    var body: some View {
        List {
            ForEach(filtered) { note in
                NavigationLink {
                    NoteEditor(note: note)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title).font(.headline)
                        Text(note.body).lineLimit(2).foregroundStyle(.secondary)
                        Text(note.updatedAt, style: .relative).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .onDelete { offsets in
                offsets.map { filtered[$0] }.forEach { context.delete($0) }
                try? context.save()
            }
        }
        .overlay {
            if notes.isEmpty {
                ContentUnavailableView("Brak notatek", systemImage: "note.text",
                                       description: Text("Powiedz „Hej Janek, zanotuj…”"))
            }
        }
        .searchable(text: $search, prompt: "Szukaj w notatkach")
        .navigationTitle("Notatki")
        .toolbar {
            Button {
                let note = Note(title: "Nowa notatka", body: "")
                context.insert(note)
                try? context.save()
            } label: { Image(systemName: "square.and.pencil") }
        }
    }
}

private struct NoteEditor: View {
    @Bindable var note: Note

    var body: some View {
        Form {
            TextField("Tytuł", text: $note.title)
            TextEditor(text: $note.body).frame(minHeight: 300)
        }
        .navigationTitle(note.title)
        .onDisappear { note.updatedAt = .now }
    }
}
