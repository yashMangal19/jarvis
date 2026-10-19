import AudioToolbox
import Foundation
import Testing
@testable import JarvisCore

/// The restart after a configuration change, against a fake tap: no microphone is opened.
@Suite struct MicSourceRestartTests {
    @Test func aRestartThatFindsNoInputIsRetriedUntilTheInputIsBack() async throws {
        let tap = FakeTap()
        let mic = MicSource(authorized: { true }, retryDelays: [0.01, 0.02], makeTap: tap.attach)
        try mic.start { _ in }
        defer { mic.stop() }

        // AirPods reconnecting: the first attempts find no usable input (J-007).
        tap.failNextStarts(3)
        tap.changeConfiguration()

        #expect(await tap.waitUntil { $0.starts == 5 })
        #expect(tap.isRunning)
    }

    @Test func stoppingCancelsAPendingRetry() async throws {
        let tap = FakeTap()
        let mic = MicSource(authorized: { true }, retryDelays: [0.01], makeTap: tap.attach)
        try mic.start { _ in }
        tap.failNextStarts(.max)
        tap.changeConfiguration()
        #expect(await tap.waitUntil { $0.starts >= 3 })

        mic.stop()
        let afterStop = tap.starts
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(tap.starts == afterStop)
        #expect(!tap.isRunning)
    }

    @Test func healthIsReconnectingThenUnavailableAndOkOnceTheInputIsBack() async throws {
        let tap = FakeTap()
        let health = HealthLog()
        let mic = MicSource(authorized: { true }, retryDelays: [0.01, 0.01, 0.01], makeTap: tap.attach)
        mic.onHealth = health.append
        try mic.start { _ in }
        defer { mic.stop() }

        tap.failNextStarts(5)
        tap.changeConfiguration()

        #expect(await tap.waitUntil { _ in health.values.last == .ok && health.values.count > 1 })
        #expect(health.values == [.reconnecting, .unavailable, .ok])
    }
}

private final class HealthLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [MicHealth] = []
    var values: [MicHealth] { lock.withLock { log } }
    func append(_ health: MicHealth) { lock.withLock { log.append(health) } }
}

/// Counts starts; fails the next few as a device with no usable input would.
private final class FakeTap: AudioTap, @unchecked Sendable {
    var onConfigurationChange: (() -> Void)?
    private let lock = NSLock()
    private var queue: DispatchQueue?
    private var failures = 0
    private var startCount = 0
    private var running = false

    var starts: Int { lock.withLock { startCount } }
    var isRunning: Bool { lock.withLock { running } }

    func attach(_ queue: DispatchQueue) -> any AudioTap {
        self.queue = queue
        return self
    }

    func failNextStarts(_ count: Int) { lock.withLock { failures = count } }

    /// As `InputTap` does: the notification hops to the owner's queue.
    func changeConfiguration() { queue?.async { self.onConfigurationChange?() } }

    func start(device: AudioDeviceID?, onSamples: @escaping ([Float], Date) -> Void) throws {
        try lock.withLock {
            startCount += 1
            if failures > 0 { failures -= 1; throw AudioError.noInput }
            running = true
        }
    }

    func stop() { lock.withLock { running = false } }

    func waitUntil(_ condition: (FakeTap) -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition(self) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition(self)
    }
}
