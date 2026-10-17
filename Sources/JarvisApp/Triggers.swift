import JarvisCore

/// Installs the ⌥Space hold, the stem squeeze, the chime and speech. Nothing else holds these objects,
/// so they live here for the life of the process.
@MainActor
enum Triggers {
    private static var hotKey: HotKey?
    private static var stem: StemTrigger?
    private static var speech: Speech?

    static func install(into jarvis: Jarvis) {
        let speech = Speech(jarvis: jarvis)
        jarvis.speak = { speech.say($0) }
        jarvis.onChime = Sounds.chime
        // Works while Stopped and during quiet hours: `Jarvis` decides what a hold does (DEC-22).
        hotKey = HotKey(pressed: { Sounds.tick(); jarvis.beginHoldCommand() },
                        released: { jarvis.endHoldCommand(); Sounds.tick() })
        stem = StemTrigger(onPress: { jarvis.stemPressed() })
        self.speech = speech
    }
}
