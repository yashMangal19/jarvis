import Foundation
import Testing
@testable import JarvisCore

struct RoomMicSourceSmokeTests {
    /// The built-in mic already is the "Me" stream, so a second stream on it would record everything twice.
    @Test func startRefusesWhenTheDefaultInputIsTheBuiltInMic() {
        let room = RoomMicSource(resolver: .init(defaultInput: { 73 }, builtIn: { 73 }))

        #expect(throws: RoomMicError.redundantWithDefaultInput) {
            try room.start { _ in }
        }
    }

    /// Real built-in mic. Needs mic permission for the terminal and a default input that is not the
    /// built-in mic (AirPods connected).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JARVIS_HW_TESTS"] == "1", "set JARVIS_HW_TESTS=1 to use the built-in mic"))
    func theBuiltInMicYieldsAThirtySecondRoomChunk() async throws {
        #expect(RoomMicSource.builtInDevice() != nil)
        let room = RoomMicSource()
        let chunk = RoomMicSmokeBox()
        try room.start { chunk.set($0) }
        defer { room.stop() }

        try await Task.sleep(nanoseconds: 32_000_000_000)
        #expect(chunk.value?.duration == 30)
        #expect(chunk.value?.source == .roomMic)
    }
}

/// Holds the first chunk handed over on the room-mic queue.
private final class RoomMicSmokeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var first: AudioChunk?
    var value: AudioChunk? { lock.lock(); defer { lock.unlock() }; return first }
    func set(_ chunk: AudioChunk) { lock.lock(); if first == nil { first = chunk }; lock.unlock() }
}
