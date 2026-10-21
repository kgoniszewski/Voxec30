import Contacts
import Foundation

/// Numer telefonu w postaci do URL-i (cyfry i „+”).
enum PhoneFormatting {
    static func dialable(_ number: String) -> String {
        number.filter { $0.isNumber || $0 == "+" }
    }

    /// Format międzynarodowy bez „+” (np. dla wa.me). Numery 9-cyfrowe traktujemy jako polskie.
    static func international(_ number: String) -> String {
        var digits = dialable(number)
        if digits.hasPrefix("+") { digits.removeFirst() }
        else if digits.hasPrefix("00") { digits.removeFirst(2) }
        else if digits.count == 9 { digits = "48" + digits }
        return digits
    }
}

/// Numer znajdujemy lokalnie – model zna tylko imię odbiorcy.
@MainActor
private func resolveNumber(_ input: JSONValue) async throws -> (name: String, number: String) {
    if let raw = input.optionalString("phone_number"), PhoneFormatting.dialable(raw).count >= 3 {
        return (raw, PhoneFormatting.dialable(raw))
    }
    let contact = try await ContactsProvider.shared.resolveSingle(try input.requiredString("contact_name"))
    guard let number = ContactsProvider.phoneNumber(of: contact, preferred: input.optionalString("number_label")) else {
        throw ToolError.notFound("numer telefonu dla „\(ContactsProvider.displayName(contact))”")
    }
    return (ContactsProvider.displayName(contact), PhoneFormatting.dialable(number))
}

struct CallTool: AssistantTool {
    let name = "phone_call"
    let description = "Dzwoni do osoby z kontaktów (numer aplikacja znajduje sama) albo na podany numer. Obsługuje zwykłe połączenie i FaceTime."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "contact_name": JSONSchema.string("Imię/nazwisko/relacja w mianowniku, np. „mama”, „Jan Kowalski”"),
            "phone_number": JSONSchema.string("Numer podyktowany wprost (zamiast kontaktu)"),
            "number_label": JSONSchema.string("Który numer: „komórka”, „praca”, „dom” (opcjonalnie)"),
            "kind": JSONSchema.enumeration(["phone", "facetime", "facetime_audio"], "Rodzaj połączenia, domyślnie phone"),
        ])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let (name, number) = try await resolveNumber(input)
        let scheme = switch input.optionalString("kind") {
        case "facetime": "facetime"
        case "facetime_audio": "facetime-audio"
        default: "tel"
        }
        guard let url = URL(string: "\(scheme)://\(number)"), await context.open(url) else {
            return .error("Nie udało się rozpocząć połączenia (aplikacja musi być na pierwszym planie albo w CarPlay).")
        }
        return .ok("Rozpoczęto połączenie z „\(name)”.")
    }
}

struct SendMessageTool: AssistantTool {
    let name = "message_send"
    let description = """
    Przygotowuje i wysyła wiadomość: SMS/iMessage albo w komunikatorze (WhatsApp, Telegram, Signal, Messenger). \
    iOS wymaga, by użytkownik potwierdził wysłanie jednym dotknięciem – powiedz mu o tym krótko. \
    Przed wywołaniem upewnij się, że treść jest zgodna z tym, co podyktował użytkownik.
    """
    var inputSchema: JSONValue {
        JSONSchema.object([
            "contact_name": JSONSchema.string("Odbiorca w mianowniku"),
            "phone_number": JSONSchema.string("Numer podyktowany wprost (zamiast kontaktu)"),
            "text": JSONSchema.string("Treść wiadomości, z poprawną polską interpunkcją i znakami"),
            "channel": JSONSchema.enumeration(["sms", "whatsapp", "telegram", "signal", "messenger"], "Kanał, domyślnie sms (iMessage)"),
        ], required: ["text"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let text = try input.requiredString("text")
        let channel = input.optionalString("channel") ?? "sms"
        if channel == "messenger" {
            // Messenger nie pozwala na wstępne wypełnienie treści – kopiujemy ją do schowka.
            UIPasteboardBridge.copy(text)
            _ = await context.open(URL(string: "fb-messenger://")!)
            return .ok("Otwarto Messengera, treść jest w schowku – użytkownik musi wybrać rozmowę i wkleić.")
        }
        let (name, number) = try await resolveNumber(input)
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))) ?? text

        switch channel {
        case "whatsapp":
            let url = URL(string: "https://wa.me/\(PhoneFormatting.international(number))?text=\(encoded)")!
            guard await context.open(url) else { return .error("Nie udało się otworzyć WhatsAppa.") }
            return .ok("Otwarto WhatsApp z wiadomością do „\(name)” – użytkownik musi nacisnąć Wyślij.")
        case "telegram":
            let url = URL(string: "tg://msg?to=+\(PhoneFormatting.international(number))&text=\(encoded)")!
            guard await context.open(url) else { return .error("Telegram nie jest zainstalowany.") }
            return .ok("Otwarto Telegram z wiadomością do „\(name)”.")
        case "signal":
            UIPasteboardBridge.copy(text)
            let url = URL(string: "sgnl://signal.me/#p/+\(PhoneFormatting.international(number))")!
            guard await context.open(url) else { return .error("Signal nie jest zainstalowany.") }
            return .ok("Otwarto rozmowę w Signalu z „\(name)”, treść jest w schowku do wklejenia.")
        default:
            if context.isAppInForeground, MessageComposerAvailability.canSendText {
                context.present(.messageComposer(recipients: [number], body: text))
                return .ok("Wiadomość do „\(name)” jest gotowa na ekranie – użytkownik musi nacisnąć Wyślij.")
            }
            let url = URL(string: "sms:\(number)&body=\(encoded)")!
            guard await context.open(url) else { return .error("Nie udało się otworzyć Wiadomości.") }
            return .ok("Otwarto Wiadomości z gotowym SMS-em do „\(name)”.")
        }
    }
}
