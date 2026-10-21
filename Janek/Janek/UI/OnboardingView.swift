import SwiftUI

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    var onFinish: () -> Void

    @State private var page = 0
    @State private var apiKey = KeychainStore.apiKey ?? ""
    @State private var verifying = false
    @State private var keyError: String?

    var body: some View {
        TabView(selection: $page) {
            welcome.tag(0)
            keyPage.tag(1)
            permissions.tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .interactiveDismissDisabled()
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer()
            VoiceOrb(state: .waitingForWakeWord).frame(width: 160, height: 160)
            Text("Cześć, jestem Janek").font(.largeTitle.bold())
            Text("Twój asystent głosowy po polsku. Powiedz „Hej Janek” i wydaj polecenie – zapiszę spotkanie, zadzwonię, poprowadzę do apteki albo nastawię minutnik.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Dalej") { withAnimation { page = 1 } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
    }

    private var keyPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Własny klucz API Anthropic").font(.title.bold())
            Text("Janek rozumie polecenia dzięki modelowi Claude firmy Anthropic. Załóż konto na console.anthropic.com, utwórz klucz i wklej go poniżej. Za użycie modelu płacisz bezpośrednio Anthropic, według ich cennika.")
                .foregroundStyle(.secondary)
            Link("Otwórz console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            SecureField("sk-ant-…", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let keyError {
                Text(keyError).foregroundStyle(.red).font(.footnote)
            }
            Text("Klucz zapisujemy wyłącznie w pęku kluczy tego iPhone'a. Bez konta, bez rejestracji, bez naszego serwera.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await verifyKey() }
            } label: {
                if verifying { ProgressView() } else { Text("Sprawdź i zapisz klucz") }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || verifying)
            Button("Używaj bez klucza – tylko model na telefonie") {
                settings.aiMode = .local
                withAnimation { page = 2 }
            }
            .frame(maxWidth: .infinity)
            .font(.footnote)
        }
        .padding(32)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Uprawnienia").font(.title.bold())
            Text("Janek potrzebuje mikrofonu i rozpoznawania mowy, by słyszeć „Hej Janek”. Nasłuch frazy działa w całości na urządzeniu. O dostęp do kalendarza, kontaktów, lokalizacji czy Zdrowia zapytam dopiero wtedy, gdy będzie potrzebny.")
                .foregroundStyle(.secondary)
            PermissionsList()
            if settings.aiMode == .local {
                Text("Tryb tylko na telefonie: pobierz model w Ustawieniach → Model na telefonie (np. Qwen3 4B lub Bielik).")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Zaczynamy") {
                settings.hasCompletedOnboarding = true
                onFinish()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(!KeychainStore.hasAPIKey && settings.aiMode != .local)
        }
        .padding(32)
    }

    private func verifyKey() async {
        verifying = true
        keyError = nil
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await AnthropicClient(apiKey: key).verifyKey()
            KeychainStore.apiKey = key
            withAnimation { page = 2 }
        } catch {
            keyError = error.localizedDescription
        }
        verifying = false
    }
}
