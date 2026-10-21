import SwiftUI

/// Ustawienia „mózgu”: Claude / hybryda / tylko lokalnie, wybór i pobieranie modeli na telefon.
struct LocalModelSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var mlx = MLXEngine.shared
    @State private var appleStatus = AppleFoundationEngine.status

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Tryb", selection: $settings.aiMode) {
                    ForEach(AIMode.allCases) { mode in
                        VStack(alignment: .leading) {
                            Text(mode.displayName)
                            Text(mode.details).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Kto rozumie polecenia")
            }

            Section {
                Picker("Silnik", selection: $settings.localEngine) {
                    ForEach(LocalEngineChoice.allCases) { Text($0.displayName).tag($0) }
                }
                LabeledContent("Apple Intelligence", value: appleStatus.description)
            } header: {
                Text("Model na telefonie")
            } footer: {
                Text("„Automatycznie” wybiera Apple Intelligence, gdy obsługuje polski, a w przeciwnym razie pobrany model. Modele MLX działają tylko przy aktywnej aplikacji (iOS nie udostępnia GPU w tle) – przy zablokowanym ekranie polecenie przejmie Claude.")
            }

            Section {
                ForEach(LocalModelPreset.allCases) { preset in
                    ModelRow(preset: preset, state: mlx.state(of: preset), isSelected: settings.localModel == preset) {
                        guard settings.localModel != preset else { return }
                        // Zwolnij poprzedni model od razu – dwa modele naraz nie zmieszczą się w pamięci.
                        MLXEngine.shared.unload()
                        settings.localModel = preset
                    }
                }
            } header: {
                Text("Modele do pobrania (MLX)")
            } footer: {
                if MLXEngine.isSupported {
                    Text("Modele pobierają się z Hugging Face (najlepiej przez Wi-Fi) i zajmują miejsce na telefonie. Wybierz model dotknięciem.")
                } else {
                    Text("Modele MLX działają tylko na fizycznym iPhonie.")
                }
            }
        }
        .navigationTitle("Model językowy")
        .onAppear { appleStatus = AppleFoundationEngine.status }
    }
}

private struct ModelRow: View {
    let preset: LocalModelPreset
    let state: MLXEngine.State
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: select) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.displayName)
                Text(preset.details).font(.caption).foregroundStyle(.secondary)
                switch state {
                case .downloading(let fraction):
                    ProgressView(value: fraction)
                case .loading:
                    Text("Wczytywanie do pamięci…").font(.caption).foregroundStyle(.secondary)
                case .ready:
                    Text("Wczytany, gotowy").font(.caption).foregroundStyle(.green)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
                default:
                    EmptyView()
                }
            }
            Spacer()
            actionButton
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }

    @ViewBuilder private var actionButton: some View {
        switch state {
        case .notDownloaded, .failed:
            Button { MLXEngine.shared.download(preset) } label: { Image(systemName: "arrow.down.circle") }
                .buttonStyle(.borderless)
                .disabled(!MLXEngine.isSupported)
                .accessibilityLabel("Pobierz")
        case .downloading:
            Button { MLXEngine.shared.cancelDownload(preset) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Anuluj pobieranie")
        case .downloaded, .loading, .ready:
            Button(role: .destructive) { MLXEngine.shared.delete(preset) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Usuń model")
        }
    }
}
