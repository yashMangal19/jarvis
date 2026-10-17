import Combine
import Foundation

public enum CommandPhase: Equatable {
    case idle
    case drafting
    case awaitingConfirmation(draft: String, corrections: Int)
    case executing
    case finished(result: String)
    case cancelled(CancelReason)
}

public enum CancelReason: Equatable {
    case declined, timeout, tooManyCorrections
    case failed(String)
}

/// The two-phase command loop: draft → read back → explicit yes → execute.
/// This is the gate `CommandRunner.execute` relies on: nothing else calls it.
@MainActor
public final class CommandSession: ObservableObject {
    @Published public private(set) var phase: CommandPhase = .idle

    private static let yes = Set(["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm",
                                  "go ahead", "do it", "haan"].map(normalise))
    /// Matched against the whole reply only: "no, send it to Prashant" is a correction.
    private static let no = Set(["no", "nope", "nah", "cancel", "stop", "nahi", "don't"].map(normalise))

    private let runner: () -> (any CommandRunner)?
    private let clock: any TimeSource
    private let speak: (String) -> Void
    private let replyTimeout: TimeInterval
    private let maxCorrections: Int

    private var active: (any CommandRunner)?
    private var command = ""
    private var corrections: [String] = []
    private var readBackAt = Date.distantPast

    public init(runner: @escaping () -> (any CommandRunner)?, clock: any TimeSource,
                speak: @escaping (String) -> Void, replyTimeout: TimeInterval = 15, maxCorrections: Int = 3) {
        self.runner = runner
        self.clock = clock
        self.speak = speak
        self.replyTimeout = replyTimeout
        self.maxCorrections = maxCorrections
    }

    public func submit(_ command: String) async {
        guard let runner = runner() else { return fail("Commands need Claude Code.") }
        await submit(command, runner: runner)
    }

    public func submit(_ command: String, runner: any CommandRunner) async {
        active = runner
        self.command = command
        corrections = []
        await draftAndReadBack(command)
    }

    public func heard(_ reply: String) async {
        tick(now: clock.now)
        guard case let .awaitingConfirmation(draft, _) = phase, let runner = active else { return }
        let r = Self.normalise(reply)
        if Self.yes.contains(r) {
            phase = .executing
            do {
                let result = try await runner.execute(draft)
                speak(result)
                phase = .finished(result: result)
            } catch {
                fail(error.localizedDescription)
            }
        } else if Self.no.contains(r) {
            speak("Cancelled.")
            phase = .cancelled(.declined)
        } else if corrections.count + 1 == maxCorrections {
            speak("Dropping it — three corrections without a yes.")
            phase = .cancelled(.tooManyCorrections)
        } else {
            corrections.append(reply)
            await draftAndReadBack(([command, "Corrections so far:"] + corrections.map { "- \($0)" }).joined(separator: "\n"))
        }
    }

    /// Cancels an unanswered read-back after `replyTimeout`, silently: a false trigger does nothing.
    public func tick(now: Date) {
        if case .awaitingConfirmation = phase, now.timeIntervalSince(readBackAt) >= replyTimeout {
            phase = .cancelled(.timeout)
        }
    }

    public func reset() {
        phase = .idle
    }

    private func draftAndReadBack(_ request: String) async {
        guard let runner = active else { return }
        phase = .drafting
        do {
            let draft = try await runner.draft(request)
            speak(draft)
            readBackAt = clock.now
            phase = .awaitingConfirmation(draft: draft, corrections: corrections.count)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        speak(message)
        phase = .cancelled(.failed(message))
    }

    /// Lowercased, trimmed, punctuation removed: "Go ahead!" → "go ahead".
    private static func normalise(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
