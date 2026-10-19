import Foundation
import Testing
@testable import JarvisCore

/// J-020: one owner of every capture source's lifecycle and health. Each case is about a source in
/// general, so it holds for the mic, the room mic and system audio alike.
@Suite struct CaptureSupervisorTests {
    /// Fails the next starts as asked; can stop itself as a live source does.
    final class Source: AudioSourceStream, @unchecked Sendable {
        var onStopped: ((SourceStop) -> Void)?
        private let lock = NSLock()
        private var failures: [AudioError] = []
        private var startCount = 0
        private var running = false
        var starts: Int { lock.withLock { startCount } }
        var isRunning: Bool { lock.withLock { running } }

        func failNextStarts(_ errors: [AudioError]) { lock.withLock { failures = errors } }

        func start(onChunk: @escaping (AudioChunk) -> Void) throws {
            try lock.withLock {
                startCount += 1
                if !failures.isEmpty { throw failures.removeFirst() }
                running = true
            }
        }
        func stop() { lock.withLock { running = false } }
        func cut() {}

        func stopItself(_ reason: SourceStop) {
            lock.withLock { running = false }
            onStopped?(reason)
        }
    }

    final class Healths: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [SourceHealth] = []
        var values: [SourceHealth] { lock.withLock { log } }
        func append(_ health: SourceHealth) { lock.withLock { log.append(health) } }
    }

    func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        return condition()
    }

    func driver(_ source: Source, _ healths: Healths) -> CaptureDriver {
        let driver = CaptureDriver(source, name: "test source", retryDelays: [0.01, 0.01, 0.01])
        driver.onHealth = healths.append
        return driver
    }

    @Test func aSourceThatStopsItselfWhileWantedIsRestartedUntilItRuns() async {
        let source = Source(), healths = Healths()
        let driver = driver(source, healths)
        driver.run(true)
        #expect(await waitUntil { source.isRunning })

        source.failNextStarts([.noInput, .noInput, .noInput, .noInput])
        source.stopItself(.failed)

        #expect(await waitUntil { source.isRunning && healths.values.last == .ok })
        #expect(source.starts == 6)
        #expect(healths.values == [.reconnecting, .unavailable, .ok])
    }

    @Test func aStartThatFailsIsRetriedToo() async {
        let source = Source(), healths = Healths()
        source.failNextStarts([.noInput, .noInput])
        let driver = driver(source, healths)
        driver.run(true)

        #expect(await waitUntil { source.isRunning && healths.values.last == .ok })
        #expect(source.starts == 3)
    }

    @Test func aSourceNotWantedIsNeitherRestartedNorUnhealthy() async throws {
        let source = Source(), healths = Healths()
        let driver = driver(source, healths)
        driver.run(true)
        #expect(await waitUntil { source.isRunning })
        driver.run(false)
        await driver.settle()

        source.stopItself(.failed)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(source.starts == 1)
        #expect(healths.values.allSatisfy { $0 == .ok })
    }

    /// Redundant (the room mic when the built-in mic is the input) and a refused permission are not faults:
    /// they are not retried and not shown as capture trouble; the permission has its own menu line.
    @Test func redundantOrRefusedIsNotRetriedAndNotUnhealthy() async throws {
        for error in [AudioError.redundantWithDefaultInput, .permissionDenied] {
            let source = Source(), healths = Healths()
            source.failNextStarts([error])
            let driver = driver(source, healths)
            driver.run(true)
            await driver.settle()
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(source.starts == 1, "\(error)")
            #expect(healths.values.allSatisfy { $0 == .ok }, "\(error)")
        }
        let source = Source(), healths = Healths()
        let driver = driver(source, healths)
        driver.run(true)
        #expect(await waitUntil { source.isRunning })
        source.stopItself(.redundant)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(source.starts == 1)
    }

    /// A change of inputs (headset back, default input changed) tries a stopped, wanted source at once.
    @Test func aChangeOfInputsTriesAStoppedSourceAtOnce() async {
        let source = Source(), healths = Healths()
        let driver = CaptureDriver(source, name: "test source", retryDelays: [60, 60])
        driver.onHealth = healths.append
        source.failNextStarts([.noInput])
        driver.run(true)
        #expect(await waitUntil { healths.values.last == .reconnecting })

        driver.inputsChanged()

        #expect(await waitUntil { source.isRunning && healths.values.last == .ok })
        #expect(source.starts == 2)
    }

    @Test func stoppingCancelsRestarts() async throws {
        let source = Source(), healths = Healths()
        let driver = driver(source, healths)
        source.failNextStarts(Array(repeating: .noInput, count: 1000))
        driver.run(true)
        #expect(await waitUntil { source.starts >= 3 })

        driver.run(false)
        await driver.settle()
        let starts = source.starts
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(source.starts == starts)
        #expect(healths.values.last == .ok)
    }
}
