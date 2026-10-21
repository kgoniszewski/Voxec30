import UIKit

/// Znane aplikacje i ich schematy URL. Schematy firm trzecich muszą być też w
/// `LSApplicationQueriesSchemes` w Info.plist, aby `canOpenURL` działało.
enum KnownApps {
    static let schemes: [String: String] = [
        "mapy": "maps://", "mapy apple": "maps://", "muzyka": "music://", "apple music": "music://",
        "kalendarz": "calshow://", "przypomnienia": "x-apple-reminderkit://", "notatki": "mobilenotes://",
        "wiadomosci": "sms://", "mail": "message://", "poczta": "message://", "zdjecia": "photos-redirect://",
        "skroty": "shortcuts://", "pogoda": "weather://", "zegar": "clock-alarm://", "facetime": "facetime://",
        "app store": "itms-apps://", "podcasty": "podcasts://", "ksiazki": "ibooks://", "pliki": "shareddocuments://",
        "portfel": "shoebox://", "zdrowie": "x-apple-health://", "telefon": "mobilephone://", "safari": "x-web-search://",
        "ustawienia janka": UIApplication.openSettingsURLString,
        "whatsapp": "whatsapp://", "messenger": "fb-messenger://", "telegram": "tg://", "signal": "sgnl://",
        "spotify": "spotify://", "youtube": "youtube://", "youtube music": "youtubemusic://", "netflix": "nflx://",
        "facebook": "fb://", "instagram": "instagram://", "tiktok": "snssdk1233://", "twitter": "twitter://",
        "google maps": "comgooglemaps://", "waze": "waze://", "uber": "uber://", "bolt": "bolt://",
        "gmail": "googlegmail://", "chrome": "googlechrome://", "teams": "msteams://", "outlook": "ms-outlook://",
        "zoom": "zoomus://", "slack": "slack://", "allegro": "allegro://", "mobilet": "mobilet://",
        "jakdojade": "jakdojade://", "revolut": "revolut://", "olx": "olx://", "audible": "audible://",
    ]

    static func scheme(for name: String) -> String? {
        let key = TextNormalizer.normalize(name)
        if let exact = schemes[key] { return exact }
        return schemes.first { key.contains($0.key) || $0.key.contains(key) }?.value
    }
}

struct OpenAppTool: AssistantTool {
    let name = "app_open"
    let description = "Otwiera aplikację na iPhonie po nazwie (np. Mapy, Spotify, WhatsApp, Ustawienia Janka). Nie wszystkie aplikacje da się otworzyć – jeśli się nie uda, zaproponuj skrót z aplikacji Skróty."
    var inputSchema: JSONValue {
        JSONSchema.object(["app_name": JSONSchema.string("Nazwa aplikacji")], required: ["app_name"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let appName = try input.requiredString("app_name")
        guard let scheme = KnownApps.scheme(for: appName), let url = URL(string: scheme) else {
            return .error("Nie znam sposobu na otwarcie „\(appName)”. Użytkownik może utworzyć w Skrótach skrót „Otwórz \(appName)” i poprosić o jego uruchomienie.")
        }
        guard await context.open(url) else { return .error("„\(appName)” nie jest zainstalowana albo nie da się jej otworzyć.") }
        return .ok("Otwarto \(appName).")
    }
}

struct RunShortcutTool: AssistantTool {
    let name = "shortcut_run"
    let description = "Uruchamia skrót użytkownika z aplikacji Skróty po nazwie (np. „Jadę do domu”, „Dobranoc”). Pozwala sterować HomeKit, wysyłać e-maile itd. Opcjonalnie przekazuje tekst jako wejście."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "shortcut_name": JSONSchema.string("Dokładna nazwa skrótu"),
            "input_text": JSONSchema.string("Tekst przekazany do skrótu (opcjonalnie)"),
        ], required: ["shortcut_name"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let shortcut = try input.requiredString("shortcut_name")
        var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")!
        var items = [URLQueryItem(name: "name", value: shortcut), URLQueryItem(name: "x-success", value: "janek://shortcut-done")]
        if let text = input.optionalString("input_text") {
            items += [URLQueryItem(name: "input", value: "text"), URLQueryItem(name: "text", value: text)]
        }
        components.queryItems = items
        guard let url = components.url, await context.open(url) else { return .error("Nie udało się uruchomić skrótu.") }
        return .ok("Uruchomiono skrót „\(shortcut)”.")
    }
}
