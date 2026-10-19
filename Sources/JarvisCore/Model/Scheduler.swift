import Foundation

/// Where production code waits on time: retries, debounces, settle looks, timeouts, the tick (J-022, DEC-51).
/// `SystemScheduler` uses real time; tests pass a virtual one they advance by hand, so every timing rule is
/// tested by when it happens, not by how fast the machine is.
public protocol Scheduler: Sendable {
    /// This scheduler's time now.
    var now: Date { get }
    /// Suspends for `seconds` of this scheduler's time; throws `CancellationError` when the task is cancelled.
    func sleep(for seconds: TimeInterval) async throws
    /// Runs `work` on `queue` once `seconds` have passed. The returned item cancels it.
    @discardableResult
    func after(_ seconds: TimeInterval, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) -> DispatchWorkItem
}

public struct SystemScheduler: Scheduler {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    @discardableResult
    public func after(_ seconds: TimeInterval, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }
}
