import SwiftUI

/// „Test modelu”: pokazuje, jak model lokalny zrozumiał polecenie – bez wykonywania akcji.
struct LocalModelTestView: View {
    @Environment(AssistantController.self) private var controller
    @State private var command = ""
    @State private var running = false
    @State private var results: [Entry] = []

    private struct Entry: Identifiable {
        let id = UUID()
        let command: String
        let engine: String
        let analysis: LocalAssistant.Analysis?
        let error: String?
    }

    private let examples = [
        "Dodaj w kalendarzu dziś wydarzenie mecz o dwudziestej pierwszej",
        "Czy mam dziś jakieś wydarzenia w kalendarzu?",
        "Nastaw minutnik na dwanaście minut",
        "Obudź mnie jutro o wpół do siódmej",
        "Zadzwoń do mamy",
        "Dopisz mleko do listy zakupów",
        "Jaka jest stolica Australii?",
    ]

    var body: some View {
        Form {
            Section {
                TextField("Polecenie", text: $command, axis: .vertical)
                    .lineLimit(1...4)
                Button {
                    Task { await run(command) }
                } label: {
                    HStack {
                        Text("Sprawdź")
                        if running { Spacer(); ProgressView() }
                    }
                }
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || running)
            } footer: {
                Text("Silnik: \(engineName). Akcje nie są wykonywane.")
            }

            Section("Przykłady") {
                ForEach(examples, id: \.self) { example in
                    Button(example) {
                        command = example
                        Task { await run(example) }
                    }
                    .disabled(running)
                }
            }

            if !results.isEmpty {
                Section("Wyniki") {
                    ForEach(results.reversed()) { entry in
                        ResultRow(entry: entry)
                    }
                }
            }
        }
        .navigationTitle("Test modelu")
    }

    private var engineName: String {
        controller.localEngineForTesting()?.displayName ?? "brak gotowego modelu na telefonie"
    }

    private func run(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        running = true
        defer { running = false }
        guard let engine = controller.localEngineForTesting() else {
            results.append(Entry(command: trimmed, engine: "-", analysis: nil,
                                 error: "Brak gotowego modelu. Pobierz model MLX albo włącz Apple Intelligence."))
            return
        }
        let analysis = await controller.analyzeLocally(trimmed, engine: engine)
        results.append(Entry(command: trimmed, engine: engine.displayName, analysis: analysis, error: nil))
    }

    private struct ResultRow: View {
        let entry: Entry

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("„\(entry.command)”").font(.subheadline.weight(.semibold))
                if let error = entry.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if let analysis = entry.analysis {
                    switch analysis.route {
                    case .run(let decision):
                        Label(decision.tool, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                        Text(Self.describe(decision.args)).font(.caption.monospaced()).textSelection(.enabled)
                    case .delegate(let reason):
                        Label("Do Claude: \(reason)", systemImage: "cloud").foregroundStyle(.orange).font(.callout)
                    }
                    if let fields = analysis.fields {
                        Text("Model: \(Self.describe(fields))").font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text("\(entry.engine) · \(analysis.usedModel ? "model" : "reguły bez modelu") · \(Self.milliseconds(analysis.duration)) ms")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }

        static func describe(_ value: JSONValue) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "-"
        }

        static func describe(_ fields: CommandFields) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(fields)).map { String(decoding: $0, as: UTF8.self) } ?? "-"
        }

        static func milliseconds(_ duration: Duration) -> Int {
            Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
        }
    }
}
