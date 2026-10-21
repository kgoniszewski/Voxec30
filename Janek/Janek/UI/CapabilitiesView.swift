import SwiftUI

/// „Co potrafi” – lista możliwości z przykładowymi poleceniami.
struct CapabilitiesView: View {
    private struct Capability: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
        let example: String
    }

    private let items: [Capability] = [
        .init(icon: "calendar", title: "Kalendarz i przypomnienia", detail: "Zapisuje, przesuwa i odwołuje spotkania, czyta plan dnia. Rozumie „w przyszły wtorek”, „za dwie godziny” i „jutro rano”.", example: "Przesuń dentystę na czwartek na piętnastą"),
        .init(icon: "phone.fill", title: "Telefon i wiadomości", detail: "Dzwoni do osób z kontaktów, pisze SMS-y i wiadomości w komunikatorach. Numer znajduje sam.", example: "Napisz do Tomka na WhatsAppie, że się spóźnię"),
        .init(icon: "map.fill", title: "Nawigacja i miejsca", detail: "Wyznacza trasę w Mapach, szuka apteki albo stacji w pobliżu i mówi, gdzie jesteś.", example: "Prowadź do najbliższej stacji Orlen"),
        .init(icon: "note.text", title: "Notatki", detail: "Zapisuje, czyta, dopisuje i wyszukuje notatki we własnej bazie Janka.", example: "Dopisz chleb do listy zakupów"),
        .init(icon: "alarm.fill", title: "Timery i budziki", detail: "Minutnik, budzik, przypomnienie o lekach – z własnym dźwiękiem alarmu.", example: "Przypominaj mi o witaminie D codziennie o ósmej"),
        .init(icon: "person.crop.circle", title: "Kontakty", detail: "Znajduje numer albo adres, dodaje nową osobę i poprawia dane istniejącej.", example: "Jaki jest adres Kasi?"),
        .init(icon: "music.note", title: "Muzyka", detail: "Włącza, zatrzymuje i przełącza utwory, wyszukuje wykonawców.", example: "Włącz Dawida Podsiadło"),
        .init(icon: "heart.fill", title: "Zdrowie i aktywność", detail: "Odczytuje kroki, puls i spalone kalorie, rozpoczyna i kończy trening. Dane zdrowotne nie opuszczają telefonu.", example: "Zacznij trening biegowy"),
        .init(icon: "doc.richtext", title: "Zdjęcia i dokumenty", detail: "Robi zdjęcia, tworzy pliki tekstowe i PDF-y.", example: "Zrób PDF z listą rzeczy na wyjazd"),
        .init(icon: "square.grid.2x2", title: "Aplikacje i skróty", detail: "Otwiera aplikacje i uruchamia Twoje własne skróty.", example: "Uruchom skrót Dobranoc"),
        .init(icon: "car.fill", title: "W samochodzie", detail: "Działa w CarPlay – powiedz „Hej Janek” bez odrywania rąk od kierownicy. Odpowiedzi słyszysz przez głośniki auta.", example: "Hej Janek, zadzwoń do żony"),
    ]

    var body: some View {
        List(items) { item in
            VStack(alignment: .leading, spacing: 6) {
                Label(item.title, systemImage: item.icon).font(.headline)
                Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                Text("„\(item.example)”").font(.subheadline.italic()).foregroundStyle(.tint)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Co potrafi Janek")
    }
}
