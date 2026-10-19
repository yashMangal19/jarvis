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

    /// Lets the driver's queue run what is already asked of it.
    func settled(_ driver: CaptureDriver) async { await driver.settle() }

    /// Moves virtual time on by one retry delay once the next try is scheduled, then lets it run.
    func nextRetry(_ clock: VirtualScheduler, _ driver: CaptureDriver, after delay: TimeInterval = 1) async {
        #expect(await clock.waitForPending())
        clock.advance(by: delay)
        await driver.settle()
    }

    func driver(_ source: Source, _ healths: Healths, _ clock: VirtualScheduler,
                delays: [TimeInterval] = [1, 1, 1]) -> CaptureDriver {
        let driver = CaptureDriver(source, name: "test source", retryDelays: delays, scheduler: clock)
        driver.onHealth = healths.append
        return driver
    }

    @Test func aSourceThatStopsItselfWhileWantedIsRestartedUntilItRuns() async {
        let source = Source(), healths = Healths(), clock = VirtualScheduler()
        let driver = driver(source, healths, clock)
        driver.run(true)
        await settled(driver)
        #expect(source.isRunning)

        source.failNextStarts([.noInput, .noInput, .noInput, .noInput])
        source.stopItself(.failed)
        await settled(driver)
        #expect(source.starts == 2)  // tried at once, and nothing more until the delay passes
        #expect(healths.values == [.reconnecting])

        await nextRetry(clock, driver)
        await nextRetry(clock, driver)
        #expect(healths.values == [.reconnecting, .unavailable])  // every delay waited once
        await nextRetry(clock, driver)
        await nextRetry(clock, driver)

        #expect(source.isRunning)
        #expect(source.starts == 6)
        #expect(healths.values == [.reconnecting, .unavailable, .ok])
        #expect(clock.pending == 0)
    }

    @Test func aStartThatFailsIsRetriedToo() async {
        let source = Source(), healths = Healths(), clock = VirtualScheduler()
        source.failNextStarts([.noInput, .noInput])
        let driver = driver(source, healths, clock)
        driver.run(true)
        await settled(driver)
        #expect(source.starts == 1)

        await nextRetry(clock, driver)
        await nextRetry(clock, driver)

        #expect(source.isRunning && source.starts == 3)
        #expect(healths.values.last == .ok)
    }

    @Test func aSourceNotWantedIsNeitherRestartedNorUnhealthy() async {
        let source = Source(), healths = Healths(), clock = VirtualScheduler()
        let driver = driver(source, healths, clock)
        driver.run(true)
        await settled(driver)
        driver.run(false)
        await settled(driver)

        source.stopItself(.failed)
        await settled(driver)
        clock.advance(by: 60)
        await settled(driver)

        #expect(source.starts == 1)
        #expect(clock.pending == 0)
        #expect(healths.values.allSatisfy { $0 == .ok })
    }

    /// Redundant (the room mic when the built-in mic is the input) and a refused permission are not faults:
    /// they are not retried and not shown as capture trouble; the permission has its own menu line.
    @Test func redundantOrRefusedIsNotRetriedAndNotUnhealthy() async {
        for error in [AudioError.redundantWithDefaultInput, .permissionDenied] {
            let source = Source(), healths = Healths(), clock = VirtualScheduler()
            source.failNextStarts([error])
            let driver = driver(source, healths, clock)
            driver.run(true)
            await settled(driver)
            #expect(source.starts == 1, "\(error)")
            #expect(clock.pending == 0, "\(error)")
            #expect(healths.values.allSatisfy { $0 == .ok }, "\(error)")
        }
        let source = Source(), healths = Healths(), clock = VirtualScheduler()
        let driver = driver(source, healths, clock)
        driver.run(true)
        await settled(driver)
        source.stopItself(.redundant)
        await settled(driver)
        #expect(source.starts == 1)
        #expect(clock.pending == 0)
    }

    /// A change of inputs (headset back, default input changed) tries a stopped, wanted source at once.
    @Test func aChangeOfInputsTriesAStoppedSourceAtOnce() async {
        let source = Source(), healths = Healths(), clock = VirtualScheduler()
        let driver = driver(source, healths, clock, delays: [60, 60])
        source.failNextStarts([.noInput])
        driver.run(true)
        await settled(driver)
        #expect(healths.values == [.reconnecting])

        driver.inputsChanged()
        await settled(driver)

        #expect(source.isRunning && source.starts == 2)
        #expect(healths.values == [.reconnecting, .ok])
    }

    @Test func stoppingCancelsRestarts() async {
        let source = Source(), healths = Healths(), clock = VirtualScheduler()
        let driver = driver(source, healths, clock)
        source.failNextStarts(Array(repeating: .noInput, count: 10))
        driver.run(true)
        await settled(driver)
        await nextRetry(clock, driver)
        #expect(source.starts == 2)

        driver.run(false)
        await settled(driver)
        clock.advance(by: 60)
        await settled(driver)

        #expect(source.starts == 2)
        #expect(healths.values.last == .ok)
    }
}
