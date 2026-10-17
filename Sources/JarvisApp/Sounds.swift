import AppKit

/// Short macOS system sounds, so nothing is bundled: a chime when the wake word is caught, a tick at
/// the start and end of a ⌥Space hold.
enum Sounds {
    static func chime() { play("Glass", volume: 0.5) }
    static func tick() { play("Tink", volume: 0.4) }

    private static func play(_ name: String, volume: Float) {
        guard let sound = NSSound(named: name) else { return }
        // A named sound is one shared instance: restart it, so the release tick plays after a quick tap.
        sound.stop()
        sound.volume = volume
        sound.play()
    }
}
