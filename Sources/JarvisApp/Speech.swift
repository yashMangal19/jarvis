import AVFoundation
import JarvisCore

/// Says Jarvis's sentences (read-backs, results, answers) through the current output, the AirPods
/// when connected. `jarvis.isSpeaking` stays true until the last queued sentence ends, which mutes the
/// wake word meanwhile so Jarvis never answers itself (D-8).
@MainActor
final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    private let jarvis: Jarvis
    private let synthesizer = AVSpeechSynthesizer()
    private var queued = 0

    init(jarvis: Jarvis) {
        self.jarvis = jarvis
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String) {
        // Nothing to say, and no finish callback to count on: an empty sentence must not leave the
        // wake word muted.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        queued += 1
        jarvis.isSpeaking = true
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.ended() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.ended() }
    }

    private func ended() {
        queued -= 1
        if queued == 0 { jarvis.isSpeaking = false }
    }
}
