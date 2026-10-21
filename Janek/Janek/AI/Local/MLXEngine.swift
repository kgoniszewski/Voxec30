import Foundation
import Observation
#if canImport(MLXLLM)
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

/// Modele open source pobierane z Hugging Face i uruchamiane przez MLX na GPU iPhone'a.
enum LocalModelPreset: String, CaseIterable, Identifiable, Sendable {
    case qwen3_4b = "mlx-community/Qwen3-4B-4bit"
    case bielik_4_5b = "futurist-ai/Bielik-4.5B-v3.0-Instruct-MLX-4bit"
    case gemma3n_e4b = "mlx-community/gemma-3n-E4B-it-lm-4bit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen3_4b: "Qwen3 4B"
        case .bielik_4_5b: "Bielik 4.5B v3 (polski)"
        case .gemma3n_e4b: "Gemma 3n E4B"
        }
    }

    var details: String {
        switch self {
        case .qwen3_4b: "≈2,3 GB · najpewniej zwraca poprawny JSON · Apache 2.0"
        case .bielik_4_5b: "≈3 GB · najlepszy polski (SpeakLeash) · Apache 2.0"
        case .gemma3n_e4b: "≈3,9 GB · Google · licencja Gemma"
        }
    }
}

@MainActor
@Observable
final class MLXEngine {
    static let shared = MLXEngine()

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case downloaded
        case loading
        case ready
        case failed(String)
    }

    private(set) var states: [LocalModelPreset: State] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var downloadTasks: [LocalModelPreset: Task<Void, Never>] = [:]
    #if canImport(MLXLLM)
    @ObservationIgnored private var container: MLXLMCommon.ModelContainer?
    #endif
    @ObservationIgnored private var loadedPreset: LocalModelPreset?

    static var isSupported: Bool {
        #if canImport(MLXLLM) && !targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private init() {
        for preset in LocalModelPreset.allCases {
            states[preset] = directory(for: preset) != nil ? .downloaded : .notDownloaded
        }
    }

    func state(of preset: LocalModelPreset) -> State { states[preset] ?? .notDownloaded }

    func isDownloaded(_ preset: LocalModelPreset) -> Bool {
        switch state(of: preset) {
        case .downloaded, .loading, .ready: true
        default: false
        }
    }

    private func directory(for preset: LocalModelPreset) -> URL? {
        guard let path = defaults.string(forKey: "mlx.dir.\(preset.rawValue)") else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Pobieranie

    func download(_ preset: LocalModelPreset) {
        guard downloadTasks[preset] == nil else { return }
        states[preset] = .downloading(0)
        downloadTasks[preset] = Task { [weak self] in
            await self?.performDownload(preset)
            self?.downloadTasks[preset] = nil
        }
    }

    func cancelDownload(_ preset: LocalModelPreset) {
        downloadTasks[preset]?.cancel()
        downloadTasks[preset] = nil
        states[preset] = .notDownloaded
    }

    private func performDownload(_ preset: LocalModelPreset) async {
        #if canImport(MLXLLM)
        do {
            let resolved = try await resolve(
                configuration: ModelConfiguration(id: preset.rawValue), from: #hubDownloader(), useLatest: false
            ) { [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    if case .downloading = self?.states[preset] { self?.states[preset] = .downloading(fraction) }
                }
            }
            try Task.checkCancellation()
            defaults.set(resolved.modelDirectory.path, forKey: "mlx.dir.\(preset.rawValue)")
            states[preset] = .downloaded
        } catch is CancellationError {
            states[preset] = .notDownloaded
        } catch {
            states[preset] = .failed(error.localizedDescription)
        }
        #else
        states[preset] = .failed("Pakiet MLX nie jest dołączony do projektu.")
        #endif
    }

    func delete(_ preset: LocalModelPreset) {
        if loadedPreset == preset { unload() }
        if let url = directory(for: preset) { try? FileManager.default.removeItem(at: url) }
        defaults.removeObject(forKey: "mlx.dir.\(preset.rawValue)")
        states[preset] = .notDownloaded
    }

    // MARK: Wczytywanie i generowanie

    /// Zwalnia pamięć (ostrzeżenie o pamięci, zmiana modelu, przejście w tło na dłużej).
    func unload() {
        #if canImport(MLXLLM)
        container = nil
        #endif
        if let loadedPreset, isDownloaded(loadedPreset) { states[loadedPreset] = .downloaded }
        loadedPreset = nil
    }

    func prepare(_ preset: LocalModelPreset) async throws {
        #if canImport(MLXLLM)
        if loadedPreset == preset, container != nil { return }
        guard let directory = directory(for: preset) else { throw ToolError.unavailable("model \(preset.displayName) nie jest pobrany") }
        unload()
        states[preset] = .loading
        do {
            container = try await LLMModelFactory.shared.loadContainer(from: directory, using: #huggingFaceTokenizerLoader())
            loadedPreset = preset
            states[preset] = .ready
        } catch {
            states[preset] = .failed(error.localizedDescription)
            throw error
        }
        #else
        throw ToolError.unavailable("MLX")
        #endif
    }

    func decide(_ command: String, preset: LocalModelPreset) async throws -> LocalDecision? {
        #if canImport(MLXLLM)
        try await prepare(preset)
        guard let container else { return nil }
        let input = UserInput(
            chat: [.system(LocalCommandRouter.instructions()), .user(command)],
            tools: nil,
            additionalContext: ["enable_thinking": false]
        )
        let lmInput = try await container.prepare(input: input)
        let stream = try await container.generate(input: lmInput, parameters: GenerateParameters(maxTokens: 200, temperature: 0.1))
        var output = ""
        for await generation in stream {
            if let chunk = generation.chunk { output += chunk }
            // Kończymy, gdy tylko obiekt JSON jest kompletny – oszczędza czas.
            if LocalCommandRouter.firstJSONObject(in: output.components(separatedBy: "</think>").last ?? output) != nil { break }
        }
        return LocalCommandRouter.parse(output)
        #else
        return nil
        #endif
    }
}
