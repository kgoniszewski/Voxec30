import Foundation
import Observation
import os
#if canImport(MLXLLM)
import HuggingFace
import MLX
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

    #if canImport(MLXLLM)
    /// Trwające wczytywanie – kolejne wywołania czekają na nie zamiast wczytywać model drugi raz.
    @ObservationIgnored private var loadingTask: Task<MLXLMCommon.ModelContainer, Error>?
    @ObservationIgnored private var loadingPreset: LocalModelPreset?
    #endif

    /// Pamięć podręczna buforów MLX domyślnie może zająć tyle, ile cały limit pamięci.
    /// Wtedy wagi zwolnionego modelu (2–4 GB) zostają w niej i nowy model wczytuje się
    /// obok nich – iOS zamyka aplikację z braku pamięci. Mały limit + czyszczenie przy zmianie.
    private static let configureMemoryOnce: Void = {
        #if canImport(MLXLLM)
        MLX.Memory.cacheLimit = 64 * 1024 * 1024
        #endif
    }()

    /// Zwalnia pamięć (ostrzeżenie o pamięci, zmiana modelu, przejście w tło).
    func unload() {
        #if canImport(MLXLLM)
        loadingTask?.cancel()
        loadingTask = nil
        if let loadingPreset, isDownloaded(loadingPreset) { states[loadingPreset] = .downloaded }
        loadingPreset = nil
        container = nil
        MLX.Memory.clearCache()
        #endif
        if let loadedPreset, isDownloaded(loadedPreset) { states[loadedPreset] = .downloaded }
        loadedPreset = nil
    }

    func prepare(_ preset: LocalModelPreset) async throws {
        #if canImport(MLXLLM)
        _ = try await loadedContainer(for: preset)
        #else
        throw ToolError.unavailable("MLX")
        #endif
    }

    #if canImport(MLXLLM)
    /// Zwraca wczytany model, w razie potrzeby zwalniając poprzedni. Wczytywania są szeregowane.
    private func loadedContainer(for preset: LocalModelPreset) async throws -> MLXLMCommon.ModelContainer {
        _ = Self.configureMemoryOnce
        if loadedPreset == preset, let container { return container }
        if loadingPreset == preset, let loadingTask { return try await loadingTask.value }

        guard let directory = directory(for: preset) else {
            throw ToolError.unavailable("model \(preset.displayName) nie jest pobrany")
        }
        // Najpierw zwolnij poprzedni model (i jego bufory), dopiero potem wczytuj nowy.
        unload()
        try Self.checkAvailableMemory(for: directory, preset: preset)

        states[preset] = .loading
        loadingPreset = preset
        let task = Task {
            try await LLMModelFactory.shared.loadContainer(from: directory, using: #huggingFaceTokenizerLoader())
        }
        loadingTask = task
        do {
            let loaded = try await task.value
            // W międzyczasie wybrano inny model albo zwolniono pamięć – nie zapisuj tego.
            guard loadingPreset == preset else {
                MLX.Memory.clearCache()
                throw CancellationError()
            }
            container = loaded
            loadedPreset = preset
            loadingTask = nil
            loadingPreset = nil
            states[preset] = .ready
            return loaded
        } catch {
            if loadingPreset == preset {
                loadingTask = nil
                loadingPreset = nil
                states[preset] = error is CancellationError ? .downloaded : .failed(error.localizedDescription)
            }
            throw error
        }
    }

    /// Wagi modelu na dysku – przybliżenie pamięci potrzebnej do wczytania.
    private static func weightsSize(in directory: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files
            .filter { $0.pathExtension == "safetensors" }
            .reduce(Int64(0)) { sum, url in sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Zamiast dać się zamknąć przez iOS, sprawdź, czy model zmieści się w pamięci aplikacji.
    private static func checkAvailableMemory(for directory: URL, preset: LocalModelPreset) throws {
        let available = Int64(os_proc_available_memory())
        let needed = weightsSize(in: directory) + 600 * 1024 * 1024 // + bufory obliczeń i pamięć podręczna rozmowy
        guard available > 0, needed > available else { return }
        let gb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_073_741_824).replacingOccurrences(of: ".", with: ",") }
        throw ToolError.unavailable(
            "pamięć dla modelu \(preset.displayName): potrzeba ok. \(gb(needed)) GB, dostępne \(gb(available)) GB. " +
            "Wybierz mniejszy model (Qwen3 4B) albo – z płatnym kontem Apple Developer – włącz uprawnienie Increased Memory Limit"
        )
    }
    #endif

    func decide(_ command: String, preset: LocalModelPreset) async throws -> LocalDecision? {
        #if canImport(MLXLLM)
        let container = try await loadedContainer(for: preset)
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
