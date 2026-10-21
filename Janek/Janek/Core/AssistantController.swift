import AVFoundation
import Observation
import SwiftUI
import UIKit

/// Stan asystenta widoczny w UI i w CarPlay.
enum AssistantState: Equatable {
    case idle
    case waitingForWakeWord
    case listening(partial: String)
    case thinking(activity: String?)
    case speaking
    case error(String)

    var title: String {
        switch self {
        case .idle: "Dotknij, aby mówić"
        case .waitingForWakeWord: "Powiedz „Hej Janek”"
        case .listening(let partial): partial.isEmpty ? "Słucham…" : partial
        case .thinking(let activity): activity ?? "Myślę…"
        case .speaking: "Mówię…"
        case .error(let message): message
        }
    }

    var isBusy: Bool {
        switch self {
        case .thinking, .speaking: true
        default: false
        }
    }
}

struct TranscriptEntry: Identifiable, Equatable {
    enum Role { case user, assistant, system }
    let id = UUID()
    let role: Role
    let text: String
    let date = Date()
}

/// Główny koordynator: nasłuch → rozpoznanie polecenia → Claude + narzędzia → odpowiedź głosowa.
@MainActor
@Observable
final class AssistantController: ToolContext {
    static let shared = AssistantController()

    private(set) var state: AssistantState = .idle
    private(set) var transcript: [TranscriptEntry] = []
    var presentedSheet: PresentedSheet?
    /// Ustawiane przez CarPlaySceneDelegate.
    var isCarPlayConnected = false

    let settings = AppSettings.shared
    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private let speech = SpeechOutput()
    @ObservationIgnored private let agent = ConversationAgent()
    @ObservationIgnored private let local = LocalAssistant()
    /// Claude zadał pytanie – odpowiedź musi wrócić do Claude (model lokalny nie zna kontekstu).
    @ObservationIgnored private var claudeFollowUpUntil = Date.distantPast
    private var awaitingClaudeFollowUp: Bool { Date.now < claudeFollowUpUntil }
    /// Silnik, który obsłużył ostatnie polecenie (widoczne w UI).
    private(set) var lastEngine: String?
    @ObservationIgnored private var currentTurn: Task<Void, Never>?
    @ObservationIgnored private var scenePhase: ScenePhase = .active
    @ObservationIgnored private var audioObservers: [NSObjectProtocol] = []

    private init() {
        listener.onEvent = { [weak self] event in self?.handle(event) }
        agent.onLocalSpeech = { [weak self] text in
            guard let self else { return }
            self.append(.assistant, text)
            self.state = .speaking
            await self.speech.speak(text, settings: self.settings)
        }
        agent.onToolActivity = { [weak self] name in
            self?.state = .thinking(activity: ToolActivity.description(for: name))
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MLXEngine.shared.unload() }
        }
        // iOS 27: sesja audio przerwana (połączenie, Siri, inna aplikacja) / system zaleca wznowienie.
        audioObservers = [
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.audioSessionBecameInactive() }
            },
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.audioSessionMayResume() }
            },
        ]
    }

    // MARK: ToolContext

    var isAppInForeground: Bool { scenePhase == .active && UIApplication.shared.applicationState == .active }

    func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url)
    }

    func present(_ sheet: PresentedSheet) {
        presentedSheet = sheet
    }

    // MARK: Cykl życia

    func scenePhaseChanged(_ phase: ScenePhase) {
        scenePhase = phase
        switch phase {
        case .active:
            if state == .idle || state == .waitingForWakeWord { resumeWakeListening() }
            local.warmUp(settings: settings)
        case .background:
            // GPU (MLX) jest w tle niedostępne – zwalniamy pamięć, żeby iOS nie zamknął aplikacji.
            MLXEngine.shared.unload()
            // Nasłuch w tle działa dzięki trybowi „audio” (pomarańczowa kropka w pasku stanu).
            if !settings.listenInBackground && !isCarPlayConnected && !state.isBusy {
                listener.stop()
                state = .idle
            }
        default:
            break
        }
    }

    func bootstrap() async {
        guard settings.hasCompletedOnboarding else { return }
        let micGranted = AudioSessionController.recordPermissionGranted ? true : await AudioSessionController.requestRecordPermission()
        let speechGranted = SpeechListener.isAuthorized ? true : await SpeechListener.requestAuthorization()
        guard micGranted, speechGranted else {
            state = .error("Janek potrzebuje dostępu do mikrofonu i rozpoznawania mowy.")
            return
        }
        resumeWakeListening()
    }

    /// Wznawia nasłuch „Hej Janek”. Gdy już trwa, nic nie robi (chyba że `forceRestart`) –
    /// scena wielokrotnie wraca do stanu aktywnego, np. po każdym oknie zgody systemu.
    func resumeWakeListening(forceRestart: Bool = false) {
        guard !state.isBusy else { return }
        listener.configure(sensitivity: settings.wakeSensitivity, onDevice: settings.onDeviceRecognition)
        guard settings.wakeWordEnabled, SpeechListener.isAuthorized, AudioSessionController.recordPermissionGranted else {
            listener.stop()
            state = .idle
            return
        }
        if listener.mode == .wakeWord && !forceRestart {
            state = .waitingForWakeWord
            return
        }
        state = .waitingForWakeWord
        Task {
            do {
                try await listener.startWakeWordListening()
            } catch {
                if state == .waitingForWakeWord { state = .error(error.localizedDescription) }
            }
        }
    }

    // MARK: Akcje użytkownika

    /// Przycisk mikrofonu / Action Button / skrót – słuchaj polecenia bez frazy.
    func startListeningManually() {
        if state.isBusy {
            cancelCurrentTurn()
        }
        listener.configure(sensitivity: settings.wakeSensitivity, onDevice: settings.onDeviceRecognition)
        Earcons.listening()
        state = .listening(partial: "")
        Task {
            do {
                try await listener.startCommandListening()
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    /// Polecenie tekstowe (pole w UI, App Intent z tekstem).
    func submit(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        listener.stop()
        runTurn(trimmed)
    }

    func cancelCurrentTurn() {
        currentTurn?.cancel()
        currentTurn = nil
        speech.stop()
        state = .idle
        resumeWakeListening()
    }

    func clearConversation() {
        agent.reset()
        claudeFollowUpUntil = .distantPast
        transcript.removeAll()
    }

    // MARK: Zdarzenia rozpoznawania

    private func handle(_ event: SpeechListener.Event) {
        switch event {
        case .wakeWordDetected(let initial):
            Earcons.listening()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            state = .listening(partial: initial)
        case .partialCommand(let text):
            state = .listening(partial: text)
        case .commandFinished(let text):
            Earcons.done()
            runTurn(text)
        case .commandTimedOut:
            state = .idle
            resumeWakeListening()
        case .error(let message):
            state = .error(message)
        }
    }

    private func audioSessionBecameInactive() {
        listener.stop()
        speech.stop()
    }

    private func audioSessionMayResume() {
        if !state.isBusy { resumeWakeListening() }
    }

    // MARK: Tura rozmowy

    private func runTurn(_ text: String) {
        append(.user, text)
        state = .thinking(activity: nil)
        currentTurn = Task { [weak self] in
            guard let self else { return }
            var followUp = false
            do {
                // 1) Model na telefonie (tryb hybrydowy/lokalny).
                if self.settings.aiMode != .cloud, !self.awaitingClaudeFollowUp,
                   let engine = self.local.engine(settings: self.settings, isForeground: self.isAppInForeground) {
                    self.state = .thinking(activity: "\(engine.displayName)…")
                    let outcome = await self.local.handle(text, engine: engine, context: self) { spoken in
                        self.append(.assistant, spoken)
                        self.state = .speaking
                        await self.speech.speak(spoken, settings: self.settings)
                    }
                    try Task.checkCancellation()
                    if case .handled(let reply) = outcome {
                        self.lastEngine = engine.displayName
                        if !reply.isEmpty {
                            self.append(.assistant, reply)
                            self.state = .speaking
                            await self.speech.speak(reply, settings: self.settings)
                        }
                        self.finishTurn(followUp: false)
                        return
                    }
                    if case .delegate(let reason) = outcome, self.settings.aiMode == .local {
                        self.append(.system, reason)
                    }
                }

                // 2) Claude.
                guard self.settings.aiMode != .local else {
                    let message = self.local.engine(settings: self.settings, isForeground: self.isAppInForeground) == nil
                        ? "Model na telefonie nie jest gotowy. Pobierz go w ustawieniach albo włącz tryb hybrydowy."
                        : "Tego nie potrafię zrobić bez Claude. Spróbuj prościej albo włącz tryb hybrydowy."
                    self.append(.assistant, message)
                    self.state = .speaking
                    await self.speech.speak(message, settings: self.settings)
                    self.finishTurn(followUp: false)
                    return
                }
                self.state = .thinking(activity: nil)
                let reply = try await self.agent.send(text, settings: self.settings, context: self, inCar: self.isCarPlayConnected)
                try Task.checkCancellation()
                self.lastEngine = self.settings.model.displayName
                if !reply.text.isEmpty {
                    self.append(.assistant, reply.text)
                    self.state = .speaking
                    await self.speech.speak(reply.text, settings: self.settings)
                }
                followUp = reply.expectsFollowUp
                self.claudeFollowUpUntil = reply.expectsFollowUp ? .now.addingTimeInterval(ConversationAgent.sessionTimeout) : .distantPast
            } catch is CancellationError {
                return
            } catch let error as AnthropicError {
                self.append(.system, error.localizedDescription)
                self.state = .speaking
                await self.speech.speak(error.spokenDescription, settings: self.settings)
            } catch {
                self.append(.system, error.localizedDescription)
                self.state = .speaking
                await self.speech.speak("Coś poszło nie tak. Spróbuj jeszcze raz.", settings: self.settings)
            }
            guard !Task.isCancelled else { return }
            self.finishTurn(followUp: followUp)
        }
    }

    private func finishTurn(followUp: Bool) {
        state = .idle
        if followUp {
            startListeningManually()
        } else {
            resumeWakeListening()
        }
    }

    private func append(_ role: TranscriptEntry.Role, _ text: String) {
        transcript.append(TranscriptEntry(role: role, text: text))
        if transcript.count > 100 { transcript.removeFirst(transcript.count - 100) }
    }
}

/// Opisy czynności widoczne w UI podczas wykonywania narzędzi.
enum ToolActivity {
    static func description(for tool: String) -> String {
        switch tool {
        case let name where name.hasPrefix("calendar"): "Sprawdzam kalendarz…"
        case let name where name.hasPrefix("reminder"): "Zapisuję przypomnienie…"
        case "phone_call": "Dzwonię…"
        case "message_send": "Przygotowuję wiadomość…"
        case let name where name.hasPrefix("maps") || name.hasPrefix("location"): "Sprawdzam mapy…"
        case let name where name.hasPrefix("note"): "Notatki…"
        case let name where name.hasPrefix("alarm") || name.hasPrefix("timer") || name.hasPrefix("medication"): "Ustawiam alarm…"
        case let name where name.hasPrefix("contact"): "Szukam w kontaktach…"
        case let name where name.hasPrefix("music"): "Muzyka…"
        case "health_read", "workout": "Zdrowie…"
        case let name where name.hasPrefix("document") || name.hasPrefix("camera"): "Dokumenty i zdjęcia…"
        case "app_open", "shortcut_run": "Otwieram…"
        default: "Myślę…"
        }
    }
}
