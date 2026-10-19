import AudioToolbox
import Foundation
import Testing
@testable import JarvisCore

/// The restart after a configuration change, against a fake tap: no microphone is opened. A restart that finds
/// no input stops the source and says so; `CaptureDriver` owns retrying (J-020, see CaptureSupervisorTests).
@Suite struct MicSourceRestartTests {
    @Test func aRestartThatFindsNoInputStopsTheSourceAndSaysSo() async throws {
        let tap = FakeTap(), stops = StopLog()
        let mic = MicSource(authorized: { true }, makeTap: tap.attach)
        mic.onStopped = stops.append
        try mic.start { _ in }

        tap.failNextStarts(1)
        tap.changeConfiguration()

        #expect(await tap.waitUntil { _ in stops.values == [.failed] })
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(tap.starts == 2)  // no retry of its own
        #expect(!tap.isRunning)
        try mic.start { _ in }  // and it starts again when asked
        #expect(tap.isRunning)
        mic.stop()
    }

    @Test func aRestartThatWorksSaysNothing() async throws {
        let tap = FakeTap(), stops = StopLog()
        let mic = MicSource(authorized: { true }, makeTap: tap.attach)
        mic.onStopped = stops.append
        try mic.start { _ in }
        defer { mic.stop() }

        tap.changeConfiguration()

        #expect(await tap.waitUntil { $0.starts == 2 })
        #expect(tap.isRunning)
        #expect(stops.values.isEmpty)
    }

    @Test func aStoppedSourceIgnoresConfigurationChanges() async throws {
        let tap = FakeTap(), stops = StopLog()
        let mic = MicSource(authorized: { true }, makeTap: tap.attach)
        mic.onStopped = stops.append
        try mic.start { _ in }
        mic.stop()

        tap.changeConfiguration()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(tap.starts == 1)
        #expect(stops.values.isEmpty)
    }
}

final class StopLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [SourceStop] = []
    var values: [SourceStop] { lock.withLock { log } }
    func append(_ stop: SourceStop) { lock.withLock { log.append(stop) } }
}

/// Counts starts; fails the next few as a device with no usable input would.
final class FakeTap: AudioTap, @unchecked Sendable {
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

    private var device: AudioDeviceID?
    var lastDevice: AudioDeviceID? { lock.withLock { device } }

    func start(device: AudioDeviceID?, onSamples: @escaping ([Float], Date) -> Void) throws {
        try lock.withLock {
            startCount += 1
            self.device = device
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
