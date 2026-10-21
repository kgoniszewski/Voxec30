import Foundation
import Security

/// Klucz API Anthropic przechowywany w pęku kluczy (tylko na tym urządzeniu, bez synchronizacji iCloud).
enum KeychainStore {
    private static let service = "pl.janek.assistant"
    private static let account = "anthropic-api-key"

    static var apiKey: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var attributes = base
            attributes[kSecValueData as String] = Data(newValue.utf8)
            // Dostępny po pierwszym odblokowaniu – potrzebne do pracy w tle i w CarPlay.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    static var hasAPIKey: Bool { !(apiKey ?? "").isEmpty }
}
