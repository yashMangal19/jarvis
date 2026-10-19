import Foundation

/// The one owner of every capture source: the mic, call audio and the room mic (J-020, DEC-49). It knows
/// whether each is wanted, starts and stops it, restarts it when it stops by itself or fails to start, and
/// is the only place health comes from. A source only does device work and says when it stopped.
final class CaptureSupervisor {
    let mic: CaptureDriver
    let systemAudio: CaptureDriver
    let roomMic: CaptureDriver

    init(sources: any SourceFactory, mic: any AudioSourceStream, retryDelays: [TimeInterval] = RestartRetry.delays,
         scheduler: any Scheduler = SystemScheduler()) {
        self.mic = CaptureDriver(mic, name: "mic", retryDelays: retryDelays, scheduler: scheduler)
        systemAudio = CaptureDriver(sources.makeSystemAudio(), name: "call audio", retryDelays: retryDelays, scheduler: scheduler)
        roomMic = CaptureDriver(sources.makeRoomMic(), name: "room mic", retryDelays: retryDelays, scheduler: scheduler)
    }

    var all: [CaptureDriver] { [mic, systemAudio, roomMic] }

    /// The inputs changed (a headset came or went, the default input moved): every wanted source that is not
    /// running is tried again at once.
    func inputsChanged() { all.forEach { $0.inputsChanged() } }

    /// Returns once every driver has run what was asked of it so far.
    func settle() async {
        for driver in all { await driver.settle() }
    }
}

/// One source under the supervisor, driven off the main actor: `SystemAudioSource.start` can block for up to
/// 20 s on ScreenCaptureKit (F-3). A serial queue per source keeps its starts, stops and cuts in the order
/// asked, and each chunk is tagged with whether Jarvis was listening when the source delivered it.
final class CaptureDriver: @unchecked Sendable {
    /// Set once, before the first `run`; the queue hop orders it before any delivery.
    var onChunk: (AudioChunk, _ heardWhileListening: Bool) -> Void = { _, _ in }
    /// Set once, before the first `run`. Called on the driver's queue when the health changes.
    var onHealth: ((SourceHealth) -> Void)? {
        get { retry.onHealth }
        set { retry.onHealth = newValue }
    }

    private let source: any AudioSourceStream
    private let name: String
    private let queue: DispatchQueue
    private let retry: RestartRetry
    private let lock = NSLock()
    private var wanted = false
    private var applyQueued = false
    private var listening = false
    /// On `queue`.
    private var running = false

    init(_ source: any AudioSourceStream, name: String, retryDelays: [TimeInterval] = RestartRetry.delays,
         scheduler: any Scheduler = SystemScheduler()) {
        self.source = source
        self.name = name
        queue = DispatchQueue(label: "jarvis.capture.\(name)")
        retry = RestartRetry(queue: queue, delays: retryDelays, scheduler: scheduler, name: name)
        source.onStopped = { [weak self] reason in
            guard let self else { return }
            queue.async { self.stoppedByItself(reason) }
        }
    }

    /// Starts or stops the source to match `on`. Only the latest wish is applied, so a slow, failing start never
    /// queues up behind itself.
    func run(_ on: Bool) {
        let queueApply = lock.withLock { () -> Bool in
            wanted = on
            defer { applyQueued = true }
            return !applyQueued
        }
        guard queueApply else { return }
        queue.async { [self] in
            let on = lock.withLock { () -> Bool in
                applyQueued = false
                return wanted
            }
            if on {
                guard !running else { return }
                retry.begin { [weak self] in self?.attemptStart() ?? true }
            } else {
                retry.cancel()
                source.stop()
                running = false
                retry.report(.ok)
            }
        }
    }

    /// Stops the source; `run(true)` starts it again (a route change re-checks the room mic, DEC-16).
    func stop() {
        queue.async { [self] in
            retry.cancel()
            source.stop()
            running = false
            retry.report(.ok)
        }
    }

    /// A wanted source that is not running is tried at once, with its backoff started afresh.
    func inputsChanged() {
        queue.async { [self] in
            guard !running, lock.withLock({ wanted }) else { return }
            retry.begin { [weak self] in self?.attemptStart() ?? true }
        }
    }

    /// Ends the chunk being recorded (through `onChunk`, still tagged with the old state), then
    /// records whether Jarvis now listens.
    func cut(listening now: Bool, byStopping: Bool = false) {
        queue.async { [self] in
            if byStopping {
                source.stop()
                running = false
            } else {
                source.cut()
            }
            lock.withLock { listening = now }
        }
    }

    /// Returns once everything asked so far has run.
    func settle() async {
        await withCheckedContinuation { done in queue.async { done.resume() } }
    }

    // MARK: on `queue`

    /// One try. True ends the tries: it runs, it isn't wanted, or it can't run for a reason that is no fault
    /// (redundant, or no permission: that has its own menu line).
    private func attemptStart() -> Bool {
        guard lock.withLock({ wanted }) else { return true }
        do {
            try source.start { [weak self] chunk in self?.deliver(chunk) }
            running = true
            return true
        } catch AudioError.redundantWithDefaultInput {
            return true
        } catch AudioError.permissionDenied {
            return true
        } catch {
            Log.capture.error("\(self.name, privacy: .public) didn't start: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
            return false
        }
    }

    private func stoppedByItself(_ reason: SourceStop) {
        running = false
        guard reason == .failed, lock.withLock({ wanted }) else { return retry.report(.ok) }
        retry.begin { [weak self] in self?.attemptStart() ?? true }
    }

    private func deliver(_ chunk: AudioChunk) {
        onChunk(chunk, lock.withLock { listening })
    }
}
