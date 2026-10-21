import CarPlay
import Observation
import UIKit

/// Scena CarPlay. Wymaga uprawnienia CarPlay od Apple (kategoria „voice-based conversation”,
/// klucz `com.apple.developer.carplay-voice-based-conversation`) – patrz README.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var voiceTemplate: CPVoiceControlTemplate?
    private var lastStateIdentifier: String?

    private enum StateID {
        static let waiting = "waiting"
        static let listening = "listening"
        static let thinking = "thinking"
        static let speaking = "speaking"
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        AssistantController.shared.isCarPlayConnected = true

        let image = UIImage(systemName: "waveform.circle.fill")
        let states = [
            CPVoiceControlState(identifier: StateID.waiting, titleVariants: ["Powiedz „Hej Janek”", "Hej Janek"], image: image, repeats: false),
            CPVoiceControlState(identifier: StateID.listening, titleVariants: ["Słucham…"], image: UIImage(systemName: "waveform"), repeats: true),
            CPVoiceControlState(identifier: StateID.thinking, titleVariants: ["Chwileczkę…"], image: UIImage(systemName: "ellipsis.circle"), repeats: true),
            CPVoiceControlState(identifier: StateID.speaking, titleVariants: ["Janek mówi"], image: UIImage(systemName: "speaker.wave.2.fill"), repeats: true),
        ]
        let template = CPVoiceControlTemplate(voiceControlStates: states)
        voiceTemplate = template
        interfaceController.setRootTemplate(template, animated: true, completion: nil)

        AssistantController.shared.resumeWakeListening()
        observeState()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        voiceTemplate = nil
        AssistantController.shared.isCarPlayConnected = false
    }

    /// Śledzi stan asystenta (Observation) i odwzorowuje go na stan szablonu głosowego.
    private func observeState() {
        guard voiceTemplate != nil else { return }
        let state = withObservationTracking {
            AssistantController.shared.state
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeState() }
        }
        let identifier: String = switch state {
        case .listening: StateID.listening
        case .thinking: StateID.thinking
        case .speaking: StateID.speaking
        default: StateID.waiting
        }
        if identifier != lastStateIdentifier {
            lastStateIdentifier = identifier
            voiceTemplate?.activateVoiceControlState(withIdentifier: identifier)
        }
    }
}
