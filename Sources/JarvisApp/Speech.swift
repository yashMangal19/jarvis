import AVFoundation
import JarvisCore

/// Says Jarvis's sentences (read-backs, results, answers) through the current output, the AirPods
/// when connected. It only reports each sentence's start and end; `Jarvis` decides when it is speaking,
/// which mutes the wake word so Jarvis never answers itself (D-8).
@MainActor
final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    private let jarvis: Jarvis
    private let synthesizer = AVSpeechSynthesizer()

    init(jarvis: Jarvis) {
        self.jarvis = jarvis
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String) {
        jarvis.speechStarted()
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    /// A barge-in was heard (DEC-55): stop now. Each sentence cut off reports `didCancel`, so speaking ends.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.jarvis.speechEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.jarvis.speechEnded() }
    }
}
