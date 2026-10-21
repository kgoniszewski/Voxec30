import Contacts
import Foundation

@MainActor
final class ContactsProvider {
    static let shared = ContactsProvider()
    let store = CNContactStore()

    static let keys: [CNKeyDescriptor] = [
        CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
        CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey,
    ].map { $0 as CNKeyDescriptor } + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]

    func requireAccess() async throws {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return
        case .notDetermined:
            guard try await store.requestAccess(for: .contacts) else { throw ToolError.permissionDenied("Kontakty") }
        default: throw ToolError.permissionDenied("Kontakty")
        }
    }

    static func displayName(_ contact: CNContact) -> String {
        CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
    }

    /// Wyszukuje kontakty po imieniu/nazwisku/pseudonimie (np. kontakt zapisany jako „Mama”).
    /// Toleruje odmianę („do Ani”, „Kowalskiemu”).
    func search(_ query: String) async throws -> [CNContact] {
        try await requireAccess()
        let store = self.store
        let keys = Self.keys
        return try await Task.detached(priority: .userInitiated) {
            let direct = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)
            if !direct.isEmpty { return direct }

            let queryStems = query.split(separator: " ").map { TextNormalizer.stem(String($0)) }.filter { !$0.isEmpty }
            guard !queryStems.isEmpty else { return [] }
            var scored: [(CNContact, Int)] = []
            try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                let fields = [contact.givenName, contact.familyName, contact.nickname, contact.organizationName]
                let stems = fields.flatMap { $0.split(separator: " ").map { TextNormalizer.stem(String($0)) } }.filter { !$0.isEmpty }
                let hits = queryStems.filter { q in stems.contains { $0 == q || ($0.hasPrefix(q) && q.count >= 3) || (q.hasPrefix($0) && $0.count >= 3) } }.count
                if hits == queryStems.count { scored.append((contact, hits)) }
            }
            return scored.sorted { $0.1 > $1.1 }.map(\.0)
        }.value
    }

    func resolveSingle(_ query: String) async throws -> CNContact {
        let matches = try await search(query)
        guard let first = matches.first else { throw ToolError.notFound("kontakt „\(query)”") }
        if matches.count > 1 {
            let names = Set(matches.prefix(5).map(Self.displayName))
            if names.count > 1 {
                throw ToolError.notFound("jednoznaczny kontakt – pasuje kilka osób: \(names.sorted().joined(separator: ", ")). Dopytaj użytkownika, o kogo chodzi")
            }
        }
        return first
    }

    /// Wybiera numer: preferuje komórkę, chyba że podano etykietę („praca”, „dom”).
    static func phoneNumber(of contact: CNContact, preferred label: String? = nil) -> String? {
        let numbers = contact.phoneNumbers
        if let label {
            let wanted = TextNormalizer.normalize(label)
            if let match = numbers.first(where: { TextNormalizer.normalize(CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0.label ?? "")).contains(wanted) }) {
                return match.value.stringValue
            }
        }
        let mobile = numbers.first { [CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone].contains($0.label ?? "") }
        return (mobile ?? numbers.first)?.value.stringValue
    }
}

struct FindContactTool: AssistantTool {
    let name = "contact_find"
    let description = "Znajduje kontakt i czyta użytkownikowi jego numer telefonu, e-mail lub adres. Dane kontaktowe są czytane lokalnie na telefonie i nie trafiają do modelu. Podawaj imię w mianowniku (np. „Ania”, nie „Ani”)."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "name": JSONSchema.string("Imię, nazwisko, pseudonim albo relacja (np. „mama”)"),
            "field": JSONSchema.enumeration(["phone", "email", "address", "all"], "Jaką informację odczytać"),
        ], required: ["name"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let contact = try await ContactsProvider.shared.resolveSingle(try input.requiredString("name"))
        let name = ContactsProvider.displayName(contact)
        let field = input.optionalString("field") ?? "phone"
        var parts: [String] = []
        if field == "phone" || field == "all" {
            let phones = contact.phoneNumbers.map { "\(CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0.label ?? "")): \($0.value.stringValue)" }
            parts.append(phones.isEmpty ? "brak numeru telefonu" : "telefon " + phones.joined(separator: ", "))
        }
        if field == "email" || field == "all" {
            let emails = contact.emailAddresses.map { $0.value as String }
            parts.append(emails.isEmpty ? "brak e-maila" : "e-mail " + emails.joined(separator: ", "))
        }
        if field == "address" || field == "all" {
            let formatter = CNPostalAddressFormatter()
            let addresses = contact.postalAddresses.map { formatter.string(from: $0.value).replacingOccurrences(of: "\n", with: ", ") }
            parts.append(addresses.isEmpty ? "brak adresu" : "adres " + addresses.joined(separator: "; "))
        }
        return .privateReadout("\(name): \(parts.joined(separator: ". ")).",
                               summaryForModel: "Znaleziono kontakt „\(name)”; dane przeczytano użytkownikowi lokalnie.")
    }
}

struct AddContactTool: AssistantTool {
    let name = "contact_add"
    let description = "Dodaje nową osobę do kontaktów."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "given_name": JSONSchema.string("Imię"),
            "family_name": JSONSchema.string("Nazwisko (opcjonalnie)"),
            "phone": JSONSchema.string("Numer telefonu (opcjonalnie)"),
            "email": JSONSchema.string("E-mail (opcjonalnie)"),
            "organization": JSONSchema.string("Firma (opcjonalnie)"),
            "note": JSONSchema.string("Notatka (opcjonalnie)"),
        ], required: ["given_name"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let provider = ContactsProvider.shared
        try await provider.requireAccess()
        let contact = CNMutableContact()
        contact.givenName = try input.requiredString("given_name")
        contact.familyName = input.optionalString("family_name") ?? ""
        contact.organizationName = input.optionalString("organization") ?? ""
        if let phone = input.optionalString("phone") {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))]
        }
        if let email = input.optionalString("email") {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
        }
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        try provider.store.execute(request)
        return .ok("Dodano kontakt \(contact.givenName) \(contact.familyName).")
    }
}

struct UpdateContactTool: AssistantTool {
    let name = "contact_update"
    let description = "Poprawia lub uzupełnia dane istniejącego kontaktu (numer, e-mail, adres, firma, imię/nazwisko)."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "name": JSONSchema.string("Kogo dotyczy zmiana (mianownik)"),
            "new_phone": JSONSchema.string("Numer telefonu do dodania/zastąpienia"),
            "replace_phone": JSONSchema.boolean("true = zastąp dotychczasowe numery, false = dodaj kolejny"),
            "new_email": JSONSchema.string("E-mail do dodania"),
            "new_address": JSONSchema.string("Adres pocztowy w jednej linii: ulica, kod, miasto"),
            "new_given_name": JSONSchema.string("Nowe imię"),
            "new_family_name": JSONSchema.string("Nowe nazwisko"),
            "new_organization": JSONSchema.string("Nowa firma"),
        ], required: ["name"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let provider = ContactsProvider.shared
        let existing = try await provider.resolveSingle(try input.requiredString("name"))
        guard let contact = existing.mutableCopy() as? CNMutableContact else { throw ToolError.unavailable("edycja kontaktu") }
        var changes: [String] = []
        if let phone = input.optionalString("new_phone") {
            let value = CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))
            contact.phoneNumbers = (input["replace_phone"]?.boolValue ?? false) ? [value] : contact.phoneNumbers + [value]
            changes.append("numer telefonu")
        }
        if let email = input.optionalString("new_email") {
            contact.emailAddresses.append(CNLabeledValue(label: CNLabelHome, value: email as NSString))
            changes.append("e-mail")
        }
        if let address = input.optionalString("new_address") {
            let postal = CNMutablePostalAddress()
            let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            postal.street = parts.first ?? address
            if parts.count > 1 {
                let cityPart = parts[1]
                if let range = cityPart.range(of: #"\d{2}-\d{3}"#, options: .regularExpression) {
                    postal.postalCode = String(cityPart[range])
                    postal.city = cityPart.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespaces)
                } else {
                    postal.city = cityPart
                }
            }
            if parts.count > 2, postal.city.isEmpty { postal.city = parts[2] }
            postal.country = "Polska"
            contact.postalAddresses.append(CNLabeledValue(label: CNLabelHome, value: postal))
            changes.append("adres")
        }
        if let value = input.optionalString("new_given_name") { contact.givenName = value; changes.append("imię") }
        if let value = input.optionalString("new_family_name") { contact.familyName = value; changes.append("nazwisko") }
        if let value = input.optionalString("new_organization") { contact.organizationName = value; changes.append("firmę") }
        guard !changes.isEmpty else { return .error("Nie podano żadnej zmiany.") }
        let request = CNSaveRequest()
        request.update(contact)
        try provider.store.execute(request)
        return .ok("Zaktualizowano \(changes.joined(separator: ", ")) dla „\(ContactsProvider.displayName(contact))”.")
    }
}
