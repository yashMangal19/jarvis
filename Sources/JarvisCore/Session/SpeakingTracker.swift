import Foundation

/// Whether Jarvis is saying something, which mutes the wake word so Jarvis never answers itself (D-8).
/// Speaking lasts until the last queued sentence ends. A finish that never arrives (a synthesizer error, no
/// voice installed) is cleared once `timeout` has passed since the latest sentence began.
struct SpeakingTracker {
    /// Longer than any sentence Jarvis says; the bound on how long a lost finish can mute the wake word.
    static let timeout: TimeInterval = 120

    private(set) var isSpeaking = false
    private var queued = 0
    private var deadline = Date.distantPast

    mutating func begin(now: Date) {
        queued += 1
        isSpeaking = true
        deadline = now.addingTimeInterval(Self.timeout)
    }

    mutating func end() {
        queued = max(0, queued - 1)
        isSpeaking = queued > 0
    }

    mutating func reset() {
        queued = 0
        isSpeaking = false
    }

    mutating func expire(now: Date) {
        if isSpeaking, now >= deadline { reset() }
    }
}
