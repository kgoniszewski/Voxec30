import AVFoundation

/// Konfiguracja AVAudioSession: jednoczesne nagrywanie i odtwarzanie, Bluetooth/CarPlay,
/// miksowanie z muzyką (ściszaną, gdy Janek mówi).
enum AudioSessionController {
    static func activate(ducking: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .allowAirPlay]
        options.insert(ducking ? .duckOthers : .mixWithOthers)
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    static var recordPermissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    static func requestRecordPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
