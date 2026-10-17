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
/// Within this type, `CommandRunner.execute` is reachable only from the yes branch of `heard`.
/// Nothing stops other code that holds a runner from calling `execute` directly.
/// Each command gets a generation: an `await` that resumes after a newer `submit` or a `reset`
/// is discarded, so a yes always executes the current draft on the runner that drafted it.
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
    private var generation = 0

    public init(runner: @escaping () -> (any CommandRunner)?, clock: any TimeSource,
                speak: @escaping (String) -> Void, replyTimeout: TimeInterval = 15, maxCorrections: Int = 3) {
        self.runner = runner
        self.clock = clock
        self.speak = speak
        self.replyTimeout = replyTimeout
        self.maxCorrections = maxCorrections
    }

    public func submit(_ command: String) async {
        guard let runner = runner() else {
            generation += 1
            return fail("Commands need Claude Code.")
        }
        await submit(command, runner: runner)
    }

    public func submit(_ command: String, runner: any CommandRunner) async {
        generation += 1
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
            let current = generation
            phase = .executing
            do {
                let result = try await runner.execute(draft)
                guard current == generation else { return }
                speak(result)
                phase = .finished(result: result)
            } catch {
                end(error, ifStill: current)
            }
        } else if Self.no.contains(r) {
            speak("Cancelled.")
            phase = .cancelled(.declined)
        } else if corrections.count + 1 >= maxCorrections {
            speak("Dropping it — \(Self.spell(maxCorrections)) correction\(maxCorrections == 1 ? "" : "s") without a yes.")
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
        generation += 1
        phase = .idle
    }

    private func draftAndReadBack(_ request: String) async {
        guard let runner = active else { return }
        let current = generation
        phase = .drafting
        do {
            let draft = try await runner.draft(request)
            guard current == generation else { return }
            speak(draft)
            readBackAt = clock.now
            phase = .awaitingConfirmation(draft: draft, corrections: corrections.count)
        } catch {
            end(error, ifStill: current)
        }
    }

    /// A stale command ends silently; a cancelled one ends quietly; anything else is spoken.
    private func end(_ error: Error, ifStill current: Int) {
        guard current == generation else { return }
        if error is CancellationError { phase = .idle } else { fail(error.localizedDescription) }
    }

    private func fail(_ message: String) {
        speak(message)
        phase = .cancelled(.failed(message))
    }

    /// Lowercased, dashes to spaces, other punctuation removed, whitespace collapsed:
    /// "Go-ahead!" → "go ahead".
    private static func normalise(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.compactMap { c -> Unicode.Scalar? in
            if c.properties.generalCategory == .dashPunctuation { return " " }
            return CharacterSet.punctuationCharacters.contains(c) ? nil : c
        }
        return String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func spell(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        f.locale = Locale(identifier: "en")
        return f.string(from: n as NSNumber) ?? String(n)
    }
}
