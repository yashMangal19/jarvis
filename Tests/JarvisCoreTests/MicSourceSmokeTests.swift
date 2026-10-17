import Foundation
import Testing
import JarvisCore

/// Real microphone and CoreAudio. Off unless `JARVIS_HW_TESTS=1`: needs a granted mic permission
/// (granted to the terminal running the tests) and an input device. Manual QA covers AirPods loss.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["JARVIS_HW_TESTS"] == "1", "set JARVIS_HW_TESTS=1 to use the microphone"))
struct MicSourceSmokeTests {
    @Test func theMonitorNamesTheCurrentInput() {
        let name = AudioRouteMonitor().current?.name

        #expect(name?.isEmpty == false)
    }

    @Test func theMicYieldsQuarterSecondFramesAndAThirtySecondChunk() async throws {
        let mic = MicSource()
        let chunk = MicSmokeBox()
        try mic.start { chunk.set($0) }
        defer { mic.stop() }

        var iterator = mic.frames.makeAsyncIterator()
        let frame = await iterator.next()
        #expect(frame?.count == 4_000)

        try await Task.sleep(nanoseconds: 32_000_000_000)
        #expect(chunk.value?.duration == 30)
        #expect(chunk.value?.source == .mic)
    }
}

/// Holds the first chunk handed over on the mic queue.
private final class MicSmokeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var first: AudioChunk?
    var value: AudioChunk? { lock.lock(); defer { lock.unlock() }; return first }
    func set(_ chunk: AudioChunk) { lock.lock(); if first == nil { first = chunk }; lock.unlock() }
}
