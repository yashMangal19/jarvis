import Foundation

/// Restarts an input after a configuration change, retrying while it fails: a device mid-switch (AirPods
/// dropping and coming back) has no usable input for a moment (J-007, J-008). Tries now, then after each
/// of `delays`, the last repeating, until a try succeeds or `cancel` is called. Health is `reconnecting`
/// until every delay has been waited once, then `unavailable`. Call every member on the owner's queue.
final class RestartRetry {
    static let delays: [TimeInterval] = [0.5, 1, 2, 4, 5]

    /// Set once, before the first start. Called on the owner's queue when the health changes.
    var onHealth: ((MicHealth) -> Void)?

    private let queue: DispatchQueue
    private let delays: [TimeInterval]
    /// Bumped by every `begin` and `cancel`, so a try scheduled before them does nothing.
    private var generation = 0
    private var health = MicHealth.ok

    init(queue: DispatchQueue, delays: [TimeInterval] = RestartRetry.delays) {
        self.queue = queue
        self.delays = delays
    }

    /// `attempt` returns whether the input is running (or should no longer be tried).
    func begin(_ attempt: @escaping () -> Bool) {
        generation += 1
        run(attempt, generation: generation, index: 0)
    }

    func cancel() { generation += 1 }

    func report(_ new: MicHealth) {
        guard new != health else { return }
        health = new
        onHealth?(new)
    }

    private func run(_ attempt: @escaping () -> Bool, generation: Int, index: Int) {
        guard generation == self.generation else { return }
        if attempt() { report(.ok); return }
        report(index + 1 < delays.count ? .reconnecting : .unavailable)
        queue.asyncAfter(deadline: .now() + delays[min(index, delays.count - 1)]) { [weak self] in
            self?.run(attempt, generation: generation, index: index + 1)
        }
    }
}
