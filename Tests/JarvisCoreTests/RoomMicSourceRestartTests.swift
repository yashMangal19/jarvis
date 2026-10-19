import AudioToolbox
import Foundation
import Testing
@testable import JarvisCore

/// The room mic's re-pin after a configuration change, against a fake tap: no microphone is opened.
@Suite struct RoomMicSourceRestartTests {
    /// AirPods are the default input (1), the built-in mic is 2.
    final class Devices: @unchecked Sendable {
        private let lock = NSLock()
        private var defaultID: AudioDeviceID = 1
        var defaultInput: AudioDeviceID {
            get { lock.withLock { defaultID } }
            set { lock.withLock { defaultID = newValue } }
        }
        var resolver: RoomMicSource.DeviceResolver { .init(defaultInput: { self.defaultInput }, builtIn: { 2 }) }
    }

    @Test func aRePinThatFailsStopsTheSourceAsFailed() async throws {
        let tap = FakeTap(), devices = Devices(), stops = StopLog()
        let room = RoomMicSource(resolver: devices.resolver, authorized: { true }, makeTap: tap.attach)
        room.onStopped = stops.append
        try room.start { _ in }

        tap.failNextStarts(1)
        tap.changeConfiguration()

        #expect(await tap.waitUntil { _ in stops.values == [.failed] })
        #expect(tap.starts == 2)
        #expect(!tap.isRunning)
    }

    @Test func aRePinThatWorksKeepsThePinOnTheBuiltInMic() async throws {
        let tap = FakeTap(), devices = Devices(), stops = StopLog()
        let room = RoomMicSource(resolver: devices.resolver, authorized: { true }, makeTap: tap.attach)
        room.onStopped = stops.append
        try room.start { _ in }
        defer { room.stop() }

        tap.changeConfiguration()

        #expect(await tap.waitUntil { $0.starts == 2 })
        #expect(tap.isRunning && tap.lastDevice == 2)
        #expect(stops.values.isEmpty)
    }

    @Test func theBuiltInMicBecomingTheDefaultStopsItAsRedundant() async throws {
        let tap = FakeTap(), devices = Devices(), stops = StopLog()
        let room = RoomMicSource(resolver: devices.resolver, authorized: { true }, makeTap: tap.attach)
        room.onStopped = stops.append
        try room.start { _ in }

        devices.defaultInput = 2
        tap.changeConfiguration()

        #expect(await tap.waitUntil { _ in stops.values == [.redundant] })
        #expect(tap.starts == 1)
        #expect(!tap.isRunning)
    }

    @Test func aMissingOrRedundantBuiltInMicRefusesToStart() {
        let gone = RoomMicSource(resolver: .init(defaultInput: { 1 }, builtIn: { nil }), authorized: { true },
                                 makeTap: FakeTap().attach)
        let same = RoomMicSource(resolver: .init(defaultInput: { 2 }, builtIn: { 2 }), authorized: { true },
                                 makeTap: FakeTap().attach)
        #expect(throws: AudioError.noInput) { try gone.start { _ in } }
        #expect(throws: AudioError.redundantWithDefaultInput) { try same.start { _ in } }
    }
}
