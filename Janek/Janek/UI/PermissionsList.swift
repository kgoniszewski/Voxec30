import AlarmKit
import AVFoundation
import Contacts
import CoreLocation
import EventKit
import Speech
import SwiftUI

/// Lista uprawnień z ich stanem i przyciskiem do nadania.
struct PermissionsList: View {
    @State private var refresh = 0

    var body: some View {
        VStack(spacing: 10) {
            row("Mikrofon", "mic.fill", granted: AudioSessionController.recordPermissionGranted) {
                _ = await AudioSessionController.requestRecordPermission()
            }
            row("Rozpoznawanie mowy", "waveform", granted: SpeechListener.isAuthorized) {
                _ = await SpeechListener.requestAuthorization()
            }
            row("Kalendarz", "calendar", granted: EKEventStore.authorizationStatus(for: .event) == .fullAccess) {
                try? await EventStoreProvider.shared.requireEvents()
            }
            row("Przypomnienia", "checklist", granted: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess) {
                try? await EventStoreProvider.shared.requireReminders()
            }
            row("Kontakty", "person.crop.circle", granted: [CNAuthorizationStatus.authorized, .limited].contains(CNContactStore.authorizationStatus(for: .contacts))) {
                try? await ContactsProvider.shared.requireAccess()
            }
            row("Lokalizacja", "location.fill", granted: [CLAuthorizationStatus.authorizedWhenInUse, .authorizedAlways].contains(LocationProvider.shared.authorizationStatus)) {
                await LocationProvider.shared.requestAuthorization()
            }
            row("Alarmy", "alarm.fill", granted: AlarmManager.shared.authorizationState == .authorized) {
                _ = try? await AlarmManager.shared.requestAuthorization()
            }
            row("Zdrowie", "heart.fill", granted: nil) {
                try? await HealthProvider.shared.requireAccess()
            }
        }
        .id(refresh)
    }

    private func row(_ title: String, _ icon: String, granted: Bool?, request: @escaping () async -> Void) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if granted == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(granted == nil ? "Ustaw" : "Zezwól") {
                    Task {
                        await request()
                        refresh += 1
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
