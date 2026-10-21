import AVFoundation
import Speech
import os

/// Ciągłe rozpoznawanie mowy (pl-PL) na urządzeniu przy użyciu SFSpeechRecognizer.
///
/// Tryby:
/// - `.wakeWord` – nasłuch frazy „Hej Janek”; zadanie rozpoznawania jest restartowane co ~50 s,
///   bo pojedyncze żądanie ma limit długości.
/// - `.command` – po wybudzeniu (lub dotknięciu przycisku) zbieramy polecenie i kończymy je po ciszy.
@MainActor
final class SpeechListener {
    enum Mode: Equatable { case idle, wakeWord, command }

    enum ListenerError: LocalizedError {
        case recognizerUnavailable
        case microphoneUnavailable

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return "Rozpoznawanie mowy po polsku jest teraz niedostępne."
            case .microphoneUnavailable:
                #if targetEnvironment(simulator)
                return "Brak mikrofonu. Mac mini nie ma wbudowanego mikrofonu – podłącz słuchawki lub mikrofon i wybierz go w Symulatorze: I/O → Audio Input. Możesz też wpisywać polecenia."
                #else
                return "Mikrofon jest niedostępny. Sprawdź zgodę na mikrofon w Ustawieniach iOS → Janek."
                #endif
            }
        }
    }

    enum Event {
        case wakeWordDetected(initialCommand: String)
        case partialCommand(String)
        case commandFinished(String)
        case commandTimedOut
        case error(String)
    }

    var onEvent: ((Event) -> Void)?

    private let logger = Logger(subsystem: "pl.janek.assistant", category: "speech")
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pl-PL"))
    private let engine = AVAudioEngine()
    private let router = AudioBufferRouter()
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var restartTask: Task<Void, Never>?
    /// Zwiększany przy każdym start/stop – przerywa start, który w międzyczasie stał się nieaktualny.
    private var startToken = 0
    private var configurationObserver: NSObjectProtocol?

    private(set) var mode: Mode = .idle
    private var detector = WakeWordDetector()
    private var onDevice = true

    // Wykrywanie końca polecenia
    private var commandText = ""
    private var commandStarted = Date()
    private var lastChange = Date()
    private var endpointTimer: Timer?
    var silenceTimeout: TimeInterval = 1.3
    var noSpeechTimeout: TimeInterval = 6

    static var isAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    var supportsOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    init() {
        // Zmiana trasy audio (słuchawki, CarPlay, połączenie) zatrzymuje silnik – wznawiamy nasłuch.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterConfigurationChange() }
        }
    }

    func configure(sensitivity: WakeSensitivity, onDevice: Bool) {
        detector = WakeWordDetector(sensitivity: sensitivity)
        self.onDevice = onDevice
    }

    // MARK: Sterowanie (wołane z głównego wątku)

    func startWakeWordListening() async throws {
        try await start(mode: .wakeWord)
    }

    /// Nasłuch polecenia bez frazy (przycisk, Action Button, odpowiedź na pytanie Janka).
    func startCommandListening(prefix: String = "") async throws {
        try await start(mode: .command)
        guard mode == .command else { return }
        beginCommand(prefix)
    }

    func stop() {
        startToken += 1
        mode = .idle
        endpointTimer?.invalidate()
        endpointTimer = nil
        restartTask?.cancel()
        finishTask()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    // MARK: Wewnętrzne

    private func start(mode newMode: Mode) async throws {
        guard let recognizer, recognizer.isAvailable else { throw ListenerError.recognizerUnavailable }
        stop()
        let token = startToken
        mode = newMode
        do {
            try await AudioSessionController.activate()
        } catch {
            if token == startToken { mode = .idle }
            throw error
        }
        // W międzyczasie ktoś zatrzymał albo ponownie uruchomił nasłuch.
        guard token == startToken else { return }

        let input = engine.inputNode
        var format = input.outputFormat(forBus: 0)
        if !Self.isUsable(format) {
            // Trasa audio bywa chwilowo w trakcie przebudowy (np. po oknie zgody) – czekamy chwilę.
            try? await Task.sleep(for: .milliseconds(500))
            guard token == startToken else { return }
            format = input.outputFormat(forBus: 0)
        }
        // Format 0 Hz / 0 kanałów = brak mikrofonu. installTap rzuciłby wtedy wyjątkiem Obj-C (awaria aplikacji).
        guard Self.isUsable(format) else {
            mode = .idle
            throw ListenerError.microphoneUnavailable
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: router.tapBlock())
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            mode = .idle
            throw error
        }
        startTask()
    }

    static func isUsable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    private func restartAfterConfigurationChange() {
        let current = mode
        guard current != .idle else { return }
        logger.info("Zmiana konfiguracji audio – wznawiam nasłuch")
        let prefix = commandText
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if current == .wakeWord {
                    try await self.startWakeWordListening()
                } else {
                    try await self.startCommandListening(prefix: prefix)
                }
            } catch {
                self.onEvent?(.error(error.localizedDescription))
            }
        }
    }

    private func startTask() {
        guard let recognizer, mode != .idle else { return }
        finishTask()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = mode == .wakeWord ? .search : .dictation
        request.addsPunctuation = mode == .command
        request.contextualStrings = ["Hej Janek", "Janek", "Janku"]
        if onDevice && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        router.request = request
        generation += 1
        let currentGeneration = generation

        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] result, error in
            self?.handle(result: result, error: error, generation: currentGeneration)
        })

        // Limit długości pojedynczego żądania – restart w trybie nasłuchu frazy.
        if mode == .wakeWord {
            restartTask?.cancel()
            restartTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(50))
                guard !Task.isCancelled, let self, self.mode == .wakeWord else { return }
                self.startTask()
            }
        }
    }

    private func finishTask() {
        router.request?.endAudio()
        router.request = nil
        generation += 1
        task?.cancel()
        task = nil
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, generation: Int) {
        guard generation == self.generation else { return }

        if let result {
            let transcript = result.bestTranscription.formattedString
            switch mode {
            case .wakeWord:
                if let match = detector.detect(in: transcript) {
                    logger.info("Wykryto frazę wybudzającą")
                    mode = .command
                    // Nowe zadanie (dyktowanie z interpunkcją); to, co już powiedziano po frazie, zachowujemy.
                    startTask()
                    beginCommand(match.command)
                    onEvent?(.wakeWordDetected(initialCommand: match.command))
                    return
                }
                if result.isFinal { startTask() }
            case .command:
                let combined = [commandPrefix, transcript].filter { !$0.isEmpty }.joined(separator: " ")
                if combined != commandText {
                    commandText = combined
                    lastChange = .now
                    onEvent?(.partialCommand(combined))
                }
                if result.isFinal, !combined.isEmpty { finishCommand() }
            case .idle:
                break
            }
        } else if let error {
            let nsError = error as NSError
            logger.debug("Błąd rozpoznawania: \(nsError.domain, privacy: .public) \(nsError.code)")
            // 1110 = brak mowy, 216/301 = anulowanie – w trybie nasłuchu po prostu restartujemy.
            if mode == .wakeWord {
                restartTask?.cancel()
                restartTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled, let self, self.mode == .wakeWord else { return }
                    self.startTask()
                }
            } else if mode == .command, !commandText.isEmpty {
                finishCommand()
            }
        }
    }

    private var commandPrefix = ""

    private func beginCommand(_ prefix: String) {
        commandPrefix = prefix
        commandText = prefix
        commandStarted = .now
        lastChange = .now
        endpointTimer?.invalidate()
        endpointTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true, block: Self.timerBlock { [weak self] in
            self?.checkEndpoint()
        })
    }

    private func checkEndpoint() {
        guard mode == .command else { return }
        let now = Date.now
        if commandText.isEmpty {
            if now.timeIntervalSince(commandStarted) > noSpeechTimeout {
                stop()
                onEvent?(.commandTimedOut)
            }
        } else if now.timeIntervalSince(lastChange) > silenceTimeout {
            finishCommand()
        }
    }

    private func finishCommand() {
        let text = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        if text.isEmpty {
            onEvent?(.commandTimedOut)
        } else {
            onEvent?(.commandFinished(text))
        }
    }
}

// MARK: - Przejścia między wątkami

extension SpeechListener {
    /// Wyniki rozpoznawania przychodzą na wątku tła – przenosimy je na główny.
    nonisolated static func resultHandler(
        _ body: @escaping @MainActor (SFSpeechRecognitionResult?, Error?) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            nonisolated(unsafe) let result = result
            nonisolated(unsafe) let error = error
            DispatchQueue.main.async { MainActor.assumeIsolated { body(result, error) } }
        }
    }

    nonisolated static func timerBlock(_ body: @escaping @MainActor () -> Void) -> @Sendable (Timer) -> Void {
        { _ in MainActor.assumeIsolated { body() } }
    }
}

/// Przekazuje bufory z wątku audio do bieżącego żądania rozpoznawania.
final class AudioBufferRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { _request } }
        set { lock.withLock { _request = newValue } }
    }

    func tapBlock() -> AVAudioNodeTapBlock {
        { [weak self] buffer, _ in self?.request?.append(buffer) }
    }
}
