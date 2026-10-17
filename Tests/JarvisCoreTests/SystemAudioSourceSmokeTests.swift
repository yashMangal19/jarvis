import Foundation
import Testing
import JarvisCore

/// Real ScreenCaptureKit. Off unless `JARVIS_HW_TESTS=1`: needs Screen Recording granted to the terminal
/// running the tests, and something playing (a video) for the 32 s the test waits.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["JARVIS_HW_TESTS"] == "1", "set JARVIS_HW_TESTS=1 to capture system audio"))
struct SystemAudioSourceSmokeTests {
    @Test func playingAudioYieldsAThirtySecondSystemAudioChunk() async throws {
        let system = SystemAudioSource()
        let chunk = SystemAudioSmokeBox()
        try system.start { chunk.set($0) }
        defer { system.stop() }

        try await Task.sleep(nanoseconds: 32_000_000_000)
        #expect(chunk.value?.duration == 30)
        #expect(chunk.value?.source == .systemAudio)
    }
}

/// Holds the first chunk handed over on the capture queue.
private final class SystemAudioSmokeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var first: AudioChunk?
    var value: AudioChunk? { lock.lock(); defer { lock.unlock() }; return first }
    func set(_ chunk: AudioChunk) { lock.lock(); if first == nil { first = chunk }; lock.unlock() }
}
