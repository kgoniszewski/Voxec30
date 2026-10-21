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
#if canImport(MLXFoundationModels) && canImport(FoundationModels, _version: 2)
import FoundationModels
import MLXFoundationModels
#endif

/// Modele open source pobierane z Hugging Face i uruchamiane przez MLX na GPU iPhone'a.
enum LocalModelPreset: String, CaseIterable, Identifiable, Sendable {
    case gemma4_e2b = "mlx-community/gemma-4-e2b-it-4bit"
    case gemma4_e4b = "mlx-community/gemma-4-e4b-it-4bit"
    case qwen3_4b_2507 = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    case qwen35_9b = "mlx-community/Qwen3.5-9B-4bit"
    // Starsze modele (zostają dla osób, które już je pobrały).
    case qwen3_4b = "mlx-community/Qwen3-4B-4bit"
    case bielik_4_5b = "futurist-ai/Bielik-4.5B-v3.0-Instruct-MLX-4bit"
    case gemma3n_e4b = "mlx-community/gemma-3n-E4B-it-lm-4bit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemma4_e2b: "Gemma 4 E2B"
        case .gemma4_e4b: "Gemma 4 E4B"
        case .qwen3_4b_2507: "Qwen3 4B Instruct 2507"
        case .qwen35_9b: "Qwen3.5 9B"
        case .qwen3_4b: "Qwen3 4B"
        case .bielik_4_5b: "Bielik 4.5B v3"
        case .gemma3n_e4b: "Gemma 3n E4B"
        }
    }

    var details: String {
        switch self {
        case .gemma4_e2b: "≈3,6 GB · Google, 140+ języków, wywoływanie funkcji · szybki"
        case .gemma4_e4b: "≈5,2 GB · Google, najlepszy polski z tej listy · wymaga Increased Memory Limit"
        case .qwen3_4b_2507: "≈2,3 GB · następca Qwen3 4B, lepiej wykonuje polecenia · najmniejszy"
        case .qwen35_9b: "≈6 GB · najmocniejszy, ale najwolniejszy · wymaga Increased Memory Limit"
        case .qwen3_4b: "≈2,3 GB · starszy"
        case .bielik_4_5b: "≈3 GB · polski model SpeakLeash · starszy"
        case .gemma3n_e4b: "≈3,9 GB · starszy"
        }
    }

    /// Przybliżony rozmiar wag (do oceny, czy model zmieści się w pamięci, jeszcze przed pobraniem).
    var approximateBytes: Int64 {
        let gb: Double = switch self {
        case .gemma4_e2b: 3.55
        case .gemma4_e4b: 5.15
        case .qwen3_4b_2507, .qwen3_4b: 2.26
        case .qwen35_9b: 5.95
        case .bielik_4_5b: 3.0
        case .gemma3n_e4b: 3.86
        }
        return Int64(gb * 1_073_741_824)
    }

    var isLegacy: Bool { [.qwen3_4b, .bielik_4_5b, .gemma3n_e4b].contains(self) }
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
    @ObservationIgnored private let logger = Logger(subsystem: "pl.janek.assistant", category: "mlx")
    #if canImport(MLXFoundationModels) && canImport(FoundationModels, _version: 2)
    /// Model MLX widziany przez API Foundation Models (generowanie ograniczone schematem `GeneratedCommand`).
    @ObservationIgnored private var languageModel: MLXLanguageModel?
    #endif

    /// Czy model zmieści się w pamięci aplikacji (wagi + ok. 0,6 GB na obliczenia).
    func fitsInMemory(_ preset: LocalModelPreset) -> Bool? {
        let available = Int64(os_proc_available_memory())
        guard available > 0 else { return nil }
        let alreadyUsed = loadedPreset.map { $0.approximateBytes } ?? 0
        return preset.approximateBytes + Self.workingMemory <= available + alreadyUsed
    }

    static let workingMemory: Int64 = 600 * 1024 * 1024

    /// Czy dostępne jest generowanie z wymuszoną strukturą (MLX przez Foundation Models, SDK iOS 27).
    static var usesGuidedGeneration: Bool {
        #if canImport(MLXFoundationModels) && canImport(FoundationModels, _version: 2)
        return true
        #else
        return false
        #endif
    }

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
        #if canImport(MLXFoundationModels) && canImport(FoundationModels, _version: 2)
        // Adapter trzyma własną kopię referencji do wag – zwolnij ją także.
        if languageModel != nil {
            languageModel = nil
            Task { await MLXLanguageModel.evictAll(); MLX.Memory.clearCache() }
        }
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
        #if canImport(MLXFoundationModels) && canImport(FoundationModels, _version: 2)
        await MLXLanguageModel.evictAll()
        MLX.Memory.clearCache()
        #endif
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
        let needed = weightsSize(in: directory) + workingMemory // + bufory obliczeń i pamięć podręczna rozmowy
        guard available > 0, needed > available else { return }
        let gb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_073_741_824).replacingOccurrences(of: ".", with: ",") }
        throw ToolError.unavailable(
            "pamięć dla modelu \(preset.displayName): potrzeba ok. \(gb(needed)) GB, dostępne \(gb(available)) GB. " +
            "Wybierz mniejszy model (np. Qwen3 4B Instruct 2507) albo – z płatnym kontem Apple Developer – włącz uprawnienie Increased Memory Limit"
        )
    }
    #endif

    /// Rozkłada polecenie na pola. Najpierw generowanie z wymuszoną strukturą (gdy SDK na to pozwala),
    /// a w razie błędu – zwykłe generowanie tekstu z odczytaniem JSON.
    func decide(_ command: String, preset: LocalModelPreset) async throws -> CommandFields? {
        #if canImport(MLXLLM)
        let container = try await loadedContainer(for: preset)
        #if canImport(MLXFoundationModels) && canImport(FoundationModels, _version: 2)
        do {
            let model = guidedModel(for: preset, container: container)
            let session = LanguageModelSession(model: model) { LocalCommandRouter.instructions() }
            let response = try await session.respond(
                to: command,
                generating: GeneratedCommand.self,
                options: GenerationOptions(samplingMode: .greedy, temperature: nil, maximumResponseTokens: 300)
            )
            return response.content.fields
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Generowanie ze schematem nie powiodło się: \(error.localizedDescription, privacy: .public)")
        }
        #endif
        return try await decideFromText(command, container: container)
        #else
        return nil
        #endif
    }

    #if canImport(MLXFoundationModels) && canImport(FoundationModels, _version: 2)
    /// Adapter Foundation Models korzystający z już wczytanego modelu (bez drugiej kopii wag w pamięci).
    private func guidedModel(for preset: LocalModelPreset, container: MLXLMCommon.ModelContainer) -> MLXLanguageModel {
        if let languageModel, languageModel.configuration.name == preset.rawValue { return languageModel }
        let directory = directory(for: preset) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let model = MLXLanguageModel(
            configuration: ModelConfiguration(id: preset.rawValue),
            capabilities: [.guidedGeneration],
            weightsLocation: { _ in directory },
            load: { _, _ in container }
        )
        languageModel = model
        return model
    }
    #endif

    #if canImport(MLXLLM)
    private func decideFromText(_ command: String, container: MLXLMCommon.ModelContainer) async throws -> CommandFields? {
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
    }
    #endif
}
