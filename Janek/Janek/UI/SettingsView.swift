import AVFoundation
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AssistantController.self) private var controller
    @State private var apiKey = KeychainStore.apiKey ?? ""
    @State private var keyStatus: String?
    @State private var testingKey = false
    @State private var previewSpeech = SpeechOutput()

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                SecureField("Klucz API (sk-ant-…)", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await saveKey() }
                } label: {
                    HStack {
                        Text("Sprawdź i zapisz")
                        if testingKey { Spacer(); ProgressView() }
                    }
                }
                .disabled(testingKey)
                if let keyStatus { Text(keyStatus).font(.footnote).foregroundStyle(.secondary) }
                Link("Klucze i rozliczenia w console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            } header: {
                Text("Własny klucz API Anthropic")
            } footer: {
                Text("Za korzystanie z modelu płacisz bezpośrednio Anthropic, według ich cennika. Klucz jest przechowywany tylko w pęku kluczy tego urządzenia.")
            }

            Section("Model") {
                Picker("Model", selection: $settings.model) {
                    ForEach(ClaudeModel.allCases) { model in
                        VStack(alignment: .leading) {
                            Text(model.displayName)
                            Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(model)
                    }
                }
                .pickerStyle(.navigationLink)
                Picker("Staranność", selection: $settings.effort) {
                    ForEach(ClaudeEffort.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Wyszukiwanie w internecie", isOn: $settings.webSearchEnabled)
            }

            Section {
                Toggle("Reaguj na „Hej Janek”", isOn: $settings.wakeWordEnabled)
                Picker("Czułość", selection: $settings.wakeSensitivity) {
                    ForEach(WakeSensitivity.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Słuchaj także w tle", isOn: $settings.listenInBackground)
                Toggle("Rozpoznawanie tylko na urządzeniu", isOn: $settings.onDeviceRecognition)
                Toggle("Dźwięki sygnalizujące", isOn: $settings.playEarcons)
            } header: {
                Text("Słowo kluczowe")
            } footer: {
                Text("Nasłuch frazy działa na urządzeniu. W tle iOS pokazuje pomarańczową kropkę mikrofonu. Gdy aplikacja zostanie zamknięta z przełącznika aplikacji, użyj przycisku Czynności albo skrótu „Hej Janek”.")
            }
            .onChange(of: settings.wakeWordEnabled) { controller.resumeWakeListening() }
            .onChange(of: settings.wakeSensitivity) { controller.resumeWakeListening() }
            .onChange(of: settings.onDeviceRecognition) { controller.resumeWakeListening() }

            Section {
                Picker("Głos", selection: Binding(get: { settings.voiceIdentifier ?? "" }, set: { settings.voiceIdentifier = $0.isEmpty ? nil : $0 })) {
                    Text("Automatyczny").tag("")
                    ForEach(SpeechOutput.polishVoices, id: \.identifier) { voice in
                        Text("\(voice.name)\(voice.quality == .premium ? " (Premium)" : voice.quality == .enhanced ? " (Rozszerzony)" : "")")
                            .tag(voice.identifier)
                    }
                }
                VStack(alignment: .leading) {
                    Text("Tempo mowy")
                    Slider(value: $settings.speechRate, in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate * 0.75)
                }
                Button("Posłuchaj") {
                    Task { await previewSpeech.speak("Cześć, tu Janek. Tak brzmię z tymi ustawieniami.", settings: settings) }
                }
            } header: {
                Text("Głos Janka")
            } footer: {
                Text("Lepsze polskie głosy (Zosia, Krzysztof Premium) pobierzesz w Ustawieniach iOS → Dostępność → Treść mówiona → Głosy → Polski.")
            }

            Section("Budziki i minutniki") {
                Picker("Dźwięk alarmu", selection: $settings.alarmSound) {
                    ForEach(AlarmSound.allCases) { Text($0.displayName).tag($0) }
                }
            }

            Section("Uprawnienia") {
                PermissionsList()
                Button("Otwórz Ustawienia iOS") {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
            }

            Section("Prywatność") {
                Text("Bez konta, bez rejestracji, bez naszego serwera. Do Anthropic trafia tylko to, co potrzebne do zrozumienia polecenia – na Twoim kluczu. Notatki, ustawienia, dane zdrowotne, numery telefonów i treść notatek zostają na telefonie i są czytane lokalnie.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Ustawienia")
    }

    private func saveKey() async {
        testingKey = true
        defer { testingKey = false }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            KeychainStore.apiKey = nil
            keyStatus = "Usunięto klucz."
            return
        }
        do {
            try await AnthropicClient(apiKey: key).verifyKey()
            KeychainStore.apiKey = key
            keyStatus = "Klucz działa i został zapisany."
        } catch {
            keyStatus = error.localizedDescription
        }
    }
}
