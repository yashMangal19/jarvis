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

    @Test func aRePinThatFailsIsRetriedUntilTheBuiltInMicIsBack() async throws {
        let tap = FakeTap(), devices = Devices(), health = HealthLog()
        let room = RoomMicSource(resolver: devices.resolver, authorized: { true }, retryDelays: [0.01, 0.01, 0.01],
                                 makeTap: tap.attach)
        room.onHealth = health.append
        try room.start { _ in }
        defer { room.stop() }

        tap.failNextStarts(5)
        tap.changeConfiguration()

        #expect(await tap.waitUntil { $0.starts == 7 })
        #expect(tap.isRunning)
        #expect(tap.lastDevice == 2)
        #expect(health.values == [.reconnecting, .unavailable, .ok])
    }

    @Test func theBuiltInMicBecomingTheDefaultStillStopsForGoodWithoutRetrying() async throws {
        let tap = FakeTap(), devices = Devices()
        let room = RoomMicSource(resolver: devices.resolver, authorized: { true }, retryDelays: [0.01],
                                 makeTap: tap.attach)
        let stopped = HealthLog()
        room.onStopped = { stopped.append(.ok) }
        try room.start { _ in }

        devices.defaultInput = 2
        tap.changeConfiguration()

        #expect(await tap.waitUntil { _ in stopped.values.count == 1 })
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(tap.starts == 1)
        #expect(!tap.isRunning)
    }

    @Test func stoppingCancelsAPendingRePin() async throws {
        let tap = FakeTap(), devices = Devices()
        let room = RoomMicSource(resolver: devices.resolver, authorized: { true }, retryDelays: [0.01],
                                 makeTap: tap.attach)
        try room.start { _ in }
        tap.failNextStarts(.max)
        tap.changeConfiguration()
        #expect(await tap.waitUntil { $0.starts >= 3 })

        room.stop()
        let afterStop = tap.starts
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(tap.starts == afterStop)
    }
}
