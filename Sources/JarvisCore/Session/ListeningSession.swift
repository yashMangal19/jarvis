import Combine
import Foundation

public enum PauseReason { case user, voice, routeLost }
public enum StopReason { case user, screenLock, quietHours }

public enum ListeningState: Equatable {
    case listening
    case paused(PauseReason)
    case stopped(StopReason)

    /// The words a gap marker uses for this state.
    var gapReason: String {
        switch self {
        case .listening: return ""
        case .paused(.routeLost): return "AirPods disconnected"
        case .paused: return "paused"
        case .stopped(.screenLock): return "screen locked"
        case .stopped(.quietHours): return "quiet hours"
        case .stopped(.user): return "stopped"
        }
    }
}

public struct Modes: Equatable {
    public var meetingMode = false
    public var demoMode = false
    public init() {}
}

public struct InputDevice: Equatable {
    public let name: String
    public let isBluetoothHeadset: Bool
    public init(name: String, isBluetoothHeadset: Bool) {
        self.name = name
        self.isBluetoothHeadset = isBluetoothHeadset
    }
}

public enum RouteEvent {
    case inputChanged(InputDevice)
    case inputLost(InputDevice)
}

/// One interval Jarvis was not listening, as `gaps(in:)` returns it: always closed.
public struct GapRecord: Equatable {
    public let start: Date
    public let end: Date
    public let reason: String
}

public enum IconState { case red, greyDot, greyPlain }

/// Listening / Paused / Stopped, the rules that move between them, and the gaps they leave.
public final class ListeningSession: ObservableObject {
    @Published public private(set) var state: ListeningState = .stopped(.user)
    @Published public var modes = Modes()
    @Published public private(set) var input: InputDevice?

    private let clock: any TimeSource
    private let sleepGuard: any SleepGuard
    private let isQuietTime: (Date) -> Bool
    /// The gap log; the last entry has `end == nil` while that gap is still open.
    private var gapLog: [(start: Date, end: Date?, reason: String)] = []
    /// What the session returns to when a screen-lock or quiet-hours stop ends. Only one of the two
    /// stops is ever the current state, so one remembered state serves both. This is what keeps a
    /// user or voice pause: lock and quiet hours stop it, and their end gives it back unchanged. A
    /// user Stop is never taken over, because `screenLocked` and `tick` leave `.stopped` states alone.
    private var stateToRestore: ListeningState = .listening

    /// `isQuietTime` is a closure rather than the blueprint's `quietHours: () -> QuietHours?` so tests
    /// can say "quiet now" without building a schedule and a calendar. T-24 passes
    /// `{ settings.quietHours?.contains($0, calendar: .current) ?? false }`.
    public init(clock: any TimeSource = SystemClock(),
                sleepGuard: any SleepGuard,
                isQuietTime: @escaping (Date) -> Bool = { _ in false }) {
        self.clock = clock
        self.sleepGuard = sleepGuard
        self.isQuietTime = isQuietTime
    }

    // MARK: user actions

    public func start() { transition(to: .listening) }
    public func resume() { transition(to: .listening) }
    public func pause(_ reason: PauseReason) { transition(to: .paused(reason)) }
    public func stop(_ reason: StopReason) { transition(to: .stopped(reason)) }

    // MARK: automatic rules

    public func handle(_ event: RouteEvent) {
        switch event {
        case .inputLost(let device):
            if input == device { input = nil }
            guard device.isBluetoothHeadset else { return }
            if state == .listening { transition(to: .paused(.routeLost)) }
            if isAutoStopped && stateToRestore == .listening { stateToRestore = .paused(.routeLost) }
        case .inputChanged(let device):
            input = device
            guard device.isBluetoothHeadset else { return }
            if state == .paused(.routeLost) { transition(to: .listening) }
            if isAutoStopped && stateToRestore == .paused(.routeLost) { stateToRestore = .listening }
        }
    }

    public func screenLocked() {
        switch state {
        case .listening, .paused: stateToRestore = state
        // `stateToRestore` already holds the pre-quiet state; the lock now owns that restore.
        case .stopped(.quietHours): break
        case .stopped: return
        }
        transition(to: .stopped(.screenLock))
    }

    public func screenUnlocked() {
        guard state == .stopped(.screenLock) else { return }
        transition(to: isQuietTime(clock.now) ? .stopped(.quietHours) : stateToRestore)
    }

    /// Quiet hours stop everything but a user Stop and a screen lock, wake word included, and give
    /// back the state from before they began.
    public func tick(now: Date) {
        if isQuietTime(now) {
            switch state {
            case .listening, .paused:
                stateToRestore = state
                transition(to: .stopped(.quietHours), at: now)
            case .stopped: break
            }
        } else if state == .stopped(.quietHours) {
            transition(to: stateToRestore, at: now)
        }
    }

    /// Stopped by screen lock or quiet hours, with `stateToRestore` to return to.
    private var isAutoStopped: Bool { state == .stopped(.screenLock) || state == .stopped(.quietHours) }

    // MARK: gaps

    /// Every not-listening interval overlapping `window`, clipped to it. An open gap ends at `now`.
    public func gaps(in window: DateInterval) -> [GapRecord] {
        let now = clock.now
        return gapLog.compactMap { gap in
            let start = max(gap.start, window.start)
            let end = min(gap.end ?? now, window.end)
            return start < end ? GapRecord(start: start, end: end, reason: gap.reason) : nil
        }
    }

    /// `"HH:MM–HH:MM: not listening (<reason>)"`, en dash, local time.
    public func gapMarkers(in window: DateInterval) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return gaps(in: window).map { gap in
            "\(formatter.string(from: gap.start))–\(formatter.string(from: gap.end)): not listening (\(gap.reason))"
        }
    }

    // MARK: derived

    public var iconState: IconState {
        switch state {
        case .listening: return .red
        case .paused: return .greyDot
        case .stopped: return .greyPlain
        }
    }

    public var statusLine: String {
        switch state {
        case .listening: return input.map { "Listening via \($0.name)" } ?? "Listening"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        }
    }

    public var topMenuItem: String {
        switch state {
        case .listening: return "Pause listening"
        case .paused: return "Resume"
        case .stopped: return "Start listening"
        }
    }

    public var wakeWordActive: Bool {
        if case .stopped = state { return false }
        return true
    }

    public var storesMemory: Bool { state == .listening }

    // MARK: the one way state changes

    /// Closes or opens the gap, keeps the sleep guard held iff listening, then publishes.
    private func transition(to next: ListeningState, at now: Date? = nil) {
        guard next != state else { return }
        let now = now ?? clock.now
        let wasListening = state == .listening
        if let open = gapLog.last, open.end == nil {
            gapLog[gapLog.count - 1].end = now
        }
        if next != .listening {
            gapLog.append((start: now, end: nil, reason: next.gapReason))
        }
        if next == .listening && !wasListening { sleepGuard.hold() }
        if wasListening && next != .listening { sleepGuard.release() }
        state = next
    }
}
