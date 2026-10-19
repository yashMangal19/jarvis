import Foundation

/// Restarts a capture source, retrying while it fails: a device mid-switch (AirPods dropping and coming back)
/// has no usable input for a moment. Used by `CaptureDriver`, the one owner of restarts (J-020). Tries now, then after each
/// of `delays`, the last repeating, until a try succeeds or `cancel` is called. Health is `reconnecting`
/// until every delay has been waited once, then `unavailable`. Call every member on the owner's queue.
final class RestartRetry {
    static let delays: [TimeInterval] = [0.5, 1, 2, 4, 5]

    /// Set once, before the first start. Called on the owner's queue when the health changes.
    var onHealth: ((SourceHealth) -> Void)?

    private let queue: DispatchQueue
    private let delays: [TimeInterval]
    private let scheduler: any Scheduler
    /// Names the source in the log: "mic", "room mic", "call audio".
    private let name: String
    /// Bumped by every `begin` and `cancel`, so a try scheduled before them does nothing.
    private var generation = 0
    private var health = SourceHealth.ok

    init(queue: DispatchQueue, delays: [TimeInterval] = RestartRetry.delays, scheduler: any Scheduler = SystemScheduler(),
         name: String) {
        self.queue = queue
        self.delays = delays
        self.scheduler = scheduler
        self.name = name
    }

    /// `attempt` returns whether the input is running (or should no longer be tried).
    func begin(_ attempt: @escaping () -> Bool) {
        generation += 1
        run(attempt, generation: generation, index: 0)
    }

    func cancel() { generation += 1 }

    func report(_ new: SourceHealth) {
        guard new != health else { return }
        health = new
        switch new {
        case .ok: Log.capture.info("\(self.name, privacy: .public) ok")
        case .reconnecting: Log.capture.notice("\(self.name, privacy: .public) not recording; restarting")
        case .unavailable: Log.capture.error("\(self.name, privacy: .public) not recording; still restarting")
        }
        onHealth?(new)
    }

    private func run(_ attempt: @escaping () -> Bool, generation: Int, index: Int) {
        guard generation == self.generation else { return }
        if attempt() { report(.ok); return }
        report(index + 1 < delays.count ? .reconnecting : .unavailable)
        scheduler.after(delays[min(index, delays.count - 1)], on: queue) { [weak self] in
            self?.run(attempt, generation: generation, index: index + 1)
        }
    }
}
