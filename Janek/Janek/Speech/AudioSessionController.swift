import AVFoundation

/// Konfiguracja AVAudioSession: jednoczesne nagrywanie i odtwarzanie, Bluetooth/CarPlay,
/// miksowanie z muzyką (ściszaną, gdy Janek mówi).
///
/// `setCategory`/`setActive` potrafią blokować wątek na dłużej (iOS ostrzega przed wołaniem ich
/// z głównego wątku), dlatego wykonujemy je na osobnej kolejce.
enum AudioSessionController {
    private static let queue = DispatchQueue(label: "pl.janek.audio-session", qos: .userInitiated)

    static func activate(ducking: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try configure(ducking: ducking)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func configure(ducking: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay]
        options.insert(ducking ? .duckOthers : .mixWithOthers)
        // Zmiana kategorii przebudowuje trasę audio – robimy ją tylko wtedy, gdy jest potrzebna.
        if session.category != .playAndRecord || session.categoryOptions != options || session.mode != .default {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
        }
        try session.setActive(true)
    }

    static func deactivate() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    static var recordPermissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    static func requestRecordPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
