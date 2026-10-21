import AlarmKit
import AVFoundation
import Contacts
import CoreLocation
import EventKit
import Speech
import SwiftUI
import UIKit

/// Lista uprawnień z ich stanem i przyciskiem do nadania.
/// Gdy zgoda została wcześniej odrzucona, iOS nie pokaże okna ponownie – wtedy otwieramy Ustawienia.
/// Błędy (np. brak usługi w symulatorze) są pokazywane pod wierszem zamiast znikać bez śladu.
struct PermissionsList: View {
    @State private var refresh = 0
    @State private var errors: [String: String] = [:]

    var body: some View {
        VStack(spacing: 10) {
            row("Mikrofon", "mic.fill", granted: AudioSessionController.recordPermissionGranted,
                denied: AVAudioApplication.shared.recordPermission == .denied) {
                _ = await AudioSessionController.requestRecordPermission()
            }
            row("Rozpoznawanie mowy", "waveform", granted: SpeechListener.isAuthorized,
                denied: [.denied, .restricted].contains(SFSpeechRecognizer.authorizationStatus())) {
                _ = await SpeechListener.requestAuthorization()
            }
            row("Kalendarz", "calendar", granted: EKEventStore.authorizationStatus(for: .event) == .fullAccess,
                denied: [.denied, .restricted, .writeOnly].contains(EKEventStore.authorizationStatus(for: .event))) {
                try await EventStoreProvider.shared.requireEvents()
            }
            row("Przypomnienia", "checklist", granted: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
                denied: [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .reminder))) {
                try await EventStoreProvider.shared.requireReminders()
            }
            row("Kontakty", "person.crop.circle",
                granted: [CNAuthorizationStatus.authorized, .limited].contains(CNContactStore.authorizationStatus(for: .contacts)),
                denied: [CNAuthorizationStatus.denied, .restricted].contains(CNContactStore.authorizationStatus(for: .contacts))) {
                try await ContactsProvider.shared.requireAccess()
            }
            row("Lokalizacja", "location.fill",
                granted: [CLAuthorizationStatus.authorizedWhenInUse, .authorizedAlways].contains(LocationProvider.shared.authorizationStatus),
                denied: [CLAuthorizationStatus.denied, .restricted].contains(LocationProvider.shared.authorizationStatus)) {
                await LocationProvider.shared.requestAuthorization()
            }
            row("Alarmy", "alarm.fill", granted: AlarmManager.shared.authorizationState == .authorized,
                denied: AlarmManager.shared.authorizationState == .denied) {
                let state = try await AlarmManager.shared.requestAuthorization()
                if state != .authorized {
                    throw PermissionError.message("Alarmy nie zostały włączone. Janek użyje zwykłych powiadomień (bez dzwonienia w trybie cichym).")
                }
            }
            row("Zdrowie", "heart.fill", granted: nil, denied: false) {
                try await HealthProvider.shared.requireAccess()
            }
        }
        .id(refresh)
    }

    private enum PermissionError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }

    private func row(_ title: String, _ icon: String, granted: Bool?, denied: Bool,
                     request: @escaping () async throws -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if granted == true {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if denied {
                    Button("Ustawienia") { openSettings() }
                        .buttonStyle(.bordered)
                } else {
                    Button(granted == nil ? "Ustaw" : "Zezwól") {
                        Task {
                            do {
                                try await request()
                                errors[title] = nil
                            } catch {
                                errors[title] = Self.describe(error, for: title)
                            }
                            refresh += 1
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let error = errors[title] {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private static func describe(_ error: Error, for title: String) -> String {
        var text = error.localizedDescription
        #if targetEnvironment(simulator)
        if title == "Alarmy" || title == "Zdrowie" {
            text += " (W symulatorze ta usługa systemowa bywa niedostępna – sprawdź na iPhonie.)"
        }
        #endif
        if title == "Zdrowie" {
            text += " Darmowe konto (Personal Team) nie obsługuje HealthKit."
        }
        return text
    }
}
