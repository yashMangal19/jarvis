import Foundation
import Testing
@testable import JarvisCore

/// Time that moves only when a test calls `advance(by:)` (J-022). Sleeps resume, and scheduled work runs on
/// its queue, in order of their due time, as the clock passes it.
final class VirtualScheduler: Scheduler, @unchecked Sendable {
    private struct Entry {
        let due: TimeInterval
        let order: Int
        let fire: () -> Void
        let isCancelled: () -> Bool
    }

    private let lock = NSLock()
    private var now_: TimeInterval = 0
    private var entries: [Entry] = []
    private var counter = 0

    /// Starts at an arbitrary fixed date; moves only with `advance`.
    var now: Date { lock.withLock { Date(timeIntervalSince1970: 1_792_000_000 + now_) } }

    /// How many sleeps and scheduled works are waiting (cancelled ones excluded).
    var pending: Int { lock.withLock { entries.filter { !$0.isCancelled() }.count } }

    func sleep(for seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        let cancelled = CancelFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                cancelled.attach(continuation)
                add(after: seconds, fire: { cancelled.resume() }, isCancelled: { cancelled.isDone })
            }
        } onCancel: {
            cancelled.cancel()
        }
    }

    @discardableResult
    func after(_ seconds: TimeInterval, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: work)
        add(after: seconds, fire: { queue.async(execute: item) }, isCancelled: { item.isCancelled })
        return item
    }

    /// Moves time on by `seconds`, firing everything that falls due on the way, earliest first.
    func advance(by seconds: TimeInterval) {
        let target = lock.withLock { now_ + seconds }
        while true {
            let next: Entry? = lock.withLock {
                guard let index = entries.indices.filter({ entries[$0].due <= target })
                        .min(by: { (entries[$0].due, entries[$0].order) < (entries[$1].due, entries[$1].order) })
                else { return nil }
                let entry = entries.remove(at: index)
                now_ = max(now_, entry.due)
                return entry
            }
            guard let next else { break }
            if !next.isCancelled() { next.fire() }
        }
        lock.withLock { now_ = target }
    }

    /// Waits (real time, briefly) until something is scheduled: code under test schedules from its own queue.
    func waitForPending(_ count: Int = 1) async -> Bool {
        for _ in 0..<500 where pending < count { try? await Task.sleep(nanoseconds: 2_000_000) }
        return pending >= count
    }

    private func add(after seconds: TimeInterval, fire: @escaping () -> Void, isCancelled: @escaping () -> Bool) {
        lock.withLock {
            counter += 1
            entries.append(Entry(due: now_ + max(0, seconds), order: counter, fire: fire, isCancelled: isCancelled))
        }
    }
}

/// One sleep's continuation, resumed exactly once: by the clock or by cancellation.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var done = false
    private var cancelledEarly = false
    var isDone: Bool { lock.withLock { done } }

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        let early = lock.withLock { () -> Bool in
            if cancelledEarly { done = true; return true }
            self.continuation = continuation
            return false
        }
        if early { continuation.resume(throwing: CancellationError()) }
    }

    func resume() { finish { $0.resume() } }
    func cancel() {
        let attached = lock.withLock { () -> Bool in
            if continuation == nil { cancelledEarly = true; return false }
            return true
        }
        if attached { finish { $0.resume(throwing: CancellationError()) } }
    }

    private func finish(_ body: (CheckedContinuation<Void, Error>) -> Void) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !done else { return nil }
            done = true
            defer { self.continuation = nil }
            return self.continuation
        }
        if let continuation { body(continuation) }
    }
}

@Suite struct VirtualSchedulerTests {
    @Test func sleepsAndWorkFireOnlyAsTimeIsAdvancedInDueOrder() async throws {
        let clock = VirtualScheduler()
        let queue = DispatchQueue(label: "virtual-test")
        let log = Log()
        clock.after(2, on: queue) { log.add("two") }
        clock.after(1, on: queue) { log.add("one") }
        let sleeper = Task { try await clock.sleep(for: 1.5); log.add("slept") }
        #expect(await clock.waitForPending(3))

        clock.advance(by: 1)
        await withCheckedContinuation { done in queue.async { done.resume() } }
        #expect(log.values == ["one"])
        clock.advance(by: 1)
        try await sleeper.value
        await withCheckedContinuation { done in queue.async { done.resume() } }
        #expect(Set(log.values) == ["one", "slept", "two"])
    }

    @Test func aCancelledSleepThrowsAndCancelledWorkNeverRuns() async {
        let clock = VirtualScheduler()
        let queue = DispatchQueue(label: "virtual-test")
        let log = Log()
        clock.after(1, on: queue) { log.add("ran") }.cancel()
        let sleeper = Task { try await clock.sleep(for: 1) }
        #expect(await clock.waitForPending(1))
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        clock.advance(by: 5)
        await withCheckedContinuation { done in queue.async { done.resume() } }
        #expect(log.values.isEmpty)
    }

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        var values: [String] { lock.withLock { log } }
        func add(_ s: String) { lock.withLock { log.append(s) } }
    }
}
