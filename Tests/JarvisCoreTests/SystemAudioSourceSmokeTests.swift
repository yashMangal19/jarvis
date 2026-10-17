import Foundation
import Testing
@testable import JarvisCore

/// The timeout around one ScreenCaptureKit completion handler, driven by hand so no capture starts.
struct SystemAudioSourceWaitTests {
    /// A start that finishes after the timeout must still reach someone, or its capture runs on unowned.
    @Test func aCompletionAfterTheTimeoutGoesToTheLateHandler() {
        var complete: ((Result<Int, any Error>) -> Void)?
        let late = SystemAudioSmokeBox<Int>()

        #expect(throws: AudioError.noInput) {
            try SystemAudioSource.wait(timeout: .milliseconds(10), { complete = $0 },
                                       late: { late.set(try? $0.get()) })
        }
        complete?(.success(7))

        #expect(late.value == 7)
    }

    @Test func aCompletionInTimeIsReturned() throws {
        let value = try SystemAudioSource.wait(timeout: .seconds(1), { (done: (Result<Int, any Error>) -> Void) in done(.success(7)) })

        #expect(value == 7)
    }
}

/// Real ScreenCaptureKit. Off unless `JARVIS_HW_TESTS=1`: needs Screen Recording granted to the terminal
/// running the tests, and something playing (a video) for the 32 s the test waits.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["JARVIS_HW_TESTS"] == "1", "set JARVIS_HW_TESTS=1 to capture system audio"))
struct SystemAudioSourceSmokeTests {
    @Test func playingAudioYieldsAThirtySecondSystemAudioChunk() async throws {
        let system = SystemAudioSource()
        let chunk = SystemAudioSmokeBox<AudioChunk>()
        try system.start { chunk.set($0) }
        defer { system.stop() }

        try await Task.sleep(nanoseconds: 32_000_000_000)
        #expect(chunk.value?.duration == 30)
        #expect(chunk.value?.source == .systemAudio)
    }
}

/// Holds the first value handed over from another queue.
private final class SystemAudioSmokeBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Value?
    var value: Value? { lock.lock(); defer { lock.unlock() }; return first }
    func set(_ value: Value?) { lock.lock(); if first == nil { first = value }; lock.unlock() }
}
