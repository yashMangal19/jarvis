import Combine
import Foundation

/// Routes what was heard after the wake word: built-in controls act on the session directly, memory
/// questions are answered from notes, and everything else goes through the confirmation loop.
/// Works while Paused (nothing heard is stored then; `ListeningSession.storesMemory` gates that in the
/// capture pipeline, not here). While Stopped only a held command routes (DEC-22).
@MainActor
public final class VoiceControlRouter {
    private let session: ListeningSession
    private let search: MemorySearch
    private let forget: ForgetLastHour
    private let commands: CommandSession
    private let speak: (String) -> Void
    private let onAnswer: (MemoryAnswer) -> Void
    private let clock: any TimeSource
    private let commandLog: CommandLog?
    /// The command being handled; a two-phase one stays here until `CommandSession` ends it.
    private var current: CommandRecord?
    private var currentStarted = Date()
    private var phaseWatch: AnyCancellable?

    public init(session: ListeningSession, search: MemorySearch, forget: ForgetLastHour, commands: CommandSession,
                speak: @escaping (String) -> Void, onAnswer: @escaping (MemoryAnswer) -> Void, clock: any TimeSource,
                commandLog: CommandLog? = nil) {
        self.session = session
        self.search = search
        self.forget = forget
        self.commands = commands
        self.speak = speak
        self.onAnswer = onAnswer
        self.clock = clock
        self.commandLog = commandLog
        // `CommandSession` publishes on the main actor, synchronously as its phase changes.
        phaseWatch = commands.$phase.sink { [weak self] phase in
            MainActor.assumeIsolated { self?.followCommand(phase) }
        }
    }

    /// What was heard after the wake word. Does nothing while Stopped.
    public func handle(_ utterance: String) async {
        if isStopped { return }
        await route(utterance, trigger: "wake word")
    }

    /// What was said during a hold (⌥Space, story 8a). Routes in every state, Stopped and quiet hours
    /// included: a hold is a deliberate command, not listening (DEC-22). With a read-back pending it is
    /// the reply, because while Stopped the mic runs only for a hold.
    public func handleHeld(_ utterance: String) async {
        await reply(utterance, trigger: "hold")
    }

    /// A reply to a pending read-back goes to the confirmation loop, unless it is a built-in control:
    /// then the pending command is cancelled aloud and the control runs. Anything else is a new utterance.
    /// The timeout is applied first, so a read-back that went unanswered does not swallow what comes next.
    /// Does nothing while Stopped.
    public func heardReply(_ text: String) async {
        if isStopped { return }
        await reply(text, trigger: "reply window")
    }

    private var isStopped: Bool {
        if case .stopped = session.state { return true }
        return false
    }

    private func route(_ utterance: String, trigger: String) async {
        guard let intent = VoiceIntentParser.parse(utterance) else {
            Log.command.info("\(trigger, privacy: .public): nothing after the wake word")
            return
        }
        // A command still waiting for its reply is replaced by this one.
        finishCurrent(.cancelled, reason: "replaced by a new command")
        current = CommandRecord(time: clock.now, trigger: trigger, mic: session.input?.name, heard: utterance,
                                intent: intent.logName, action: "")
        currentStarted = Date()
        await act(on: intent)
    }

    private func reply(_ text: String, trigger: String) async {
        commands.tick(now: clock.now)
        guard case .awaitingConfirmation = commands.phase else { return await route(text, trigger: trigger) }
        if let intent = VoiceIntentParser.parse(text), intent.isBuiltInControl {
            current?.replies.append(text)
            current?.said.append("Cancelled.")
            finishCurrent(.cancelled, reason: "interrupted by a control")
            commands.reset()
            speak("Cancelled.")
            await route(text, trigger: trigger)
        } else {
            current?.replies.append(text)
            await commands.heard(text)
        }
    }

    private func act(on intent: VoiceIntent) async {
        switch intent {
        case .pause, .resume, .meetingMode, .demoMode:
            let (action, said) = perform(intent)
            done(action, saying: said)
        case .didYouMean(let candidates):
            // Never sent to a command runner: Jarvis asks, and acts only on a yes (J-021, DEC-50).
            let control = candidates.first(where: changesSomething) ?? candidates[0]
            current?.intent = "didYouMean(\(control.logName))"
            current?.action = "ask"
            if control == .forgetLastHour {
                // Its own read-back already asks before anything is deleted.
                await commands.submit("forget the last hour", runner: ForgetRunner(forget: forget, clock: clock))
            } else {
                await commands.submit(control.spoken, runner: ControlRunner(
                    question: "Did you mean \(control.spoken)?", run: { [weak self] in self?.perform(control).said ?? "" }))
            }
        case .forgetLastHour:
            current?.action = "read back"
            await commands.submit("forget the last hour", runner: ForgetRunner(forget: forget, clock: clock))
        case .memoryQuestion(let question):
            // A Stop said while the answer is written wins, and a cancelled search ends quietly. A question
            // held while already Stopped is still answered.
            let stoppedBefore = isStopped
            current?.action = "search notes"
            do {
                let answer = try await search.answer(question)
                if isStopped, !stoppedBefore { return finishCurrent(.cancelled, reason: "stopped") }
                done("answered", saying: answer.text)
                onAnswer(answer)
            } catch is CancellationError {
                finishCurrent(.cancelled, reason: "cancelled")
            } catch {
                if isStopped, !stoppedBefore { return finishCurrent(.cancelled, reason: "stopped") }
                current?.said.append("I couldn't search my notes.")
                finishCurrent(.failed, reason: "search failed: \(error.localizedDescription)")
                speak("I couldn't search my notes.")
            }
        case .toolCommand(let command):
            current?.action = "read back"
            await commands.submit(command)
        }
    }

    /// Runs a built-in control that needs no confirmation; returns the action's name and what to say.
    private func perform(_ control: VoiceIntent) -> (action: String, said: String) {
        switch control {
        case .pause:
            session.pause(.voice)
            return ("paused", "Paused.")
        case .resume:
            // A route-lost pause is ended by voice too: capture carries on from the MacBook mic, and the
            // headset is picked up again when it reconnects.
            let headsetWasLost = session.state == .paused(.routeLost)
            session.resume()
            return ("resumed", headsetWasLost ? "Listening through the MacBook mic." : "Listening.")
        case .meetingMode(let on):
            session.modes.meetingMode = on
            return (on ? "meeting mode on" : "meeting mode off", on ? "Meeting mode on." : "Meeting mode off.")
        case .demoMode(let on):
            session.modes.demoMode = on
            return (on ? "demo mode on" : "demo mode off", on ? "Demo mode on." : "Demo mode off.")
        case .forgetLastHour, .memoryQuestion, .toolCommand, .didYouMean:
            preconditionFailure("not a direct control: \(control.logName)")
        }
    }

    /// Of several equally close controls, the one that would change something: with Meeting mode on,
    /// "meeting mode of" means off.
    private func changesSomething(_ control: VoiceIntent) -> Bool {
        switch control {
        case .meetingMode(let on): return session.modes.meetingMode != on
        case .demoMode(let on): return session.modes.demoMode != on
        case .pause: return session.state == .listening
        case .resume: if case .paused = session.state { return true } else { return false }
        default: return true
        }
    }

    /// Speaks `text` and ends the current command as done.
    private func done(_ action: String, saying text: String) {
        current?.action = action
        current?.said.append(text)
        finishCurrent(.done)
        speak(text)
    }

    /// A two-phase command's record follows its phases and is written when it ends.
    private func followCommand(_ phase: CommandPhase) {
        guard current != nil else { return }
        switch phase {
        case .idle, .drafting:
            break
        case .awaitingConfirmation(let draft, _):
            if current?.said.last != draft { current?.said.append(draft) }
        case .executing:
            current?.action = "run"
        case .finished(let result):
            current?.said.append(result)
            finishCurrent(.done)
        case .cancelled(let reason):
            switch reason {
            case .declined:
                current?.said.append("Cancelled.")
                finishCurrent(.cancelled, reason: "declined")
            case .timeout: finishCurrent(.cancelled, reason: "no reply")
            case .tooManyCorrections: finishCurrent(.cancelled, reason: "too many corrections")
            case .failed(let message):
                current?.said.append(message)
                finishCurrent(.failed, reason: message)
            }
        }
    }

    /// Writes the current command, if any, to the command log, and its names to the unified log.
    private func finishCurrent(_ outcome: CommandRecord.Outcome, reason: String? = nil) {
        guard var record = current else { return }
        current = nil
        record.outcome = outcome
        record.reason = reason
        let seconds = Date().timeIntervalSince(currentStarted)
        Log.command.info("""
            \(record.trigger, privacy: .public) → \(record.intent, privacy: .public) → \
            \(record.action, privacy: .public) → \(outcome.rawValue, privacy: .public) \
            in \(seconds, format: .fixed(precision: 1), privacy: .public) s
            """)
        do { try commandLog?.append(record) } catch {
            Log.command.error("Command record not written: \(error.logKind, privacy: .public)")
        }
    }
}

private extension VoiceIntent {
    /// The case without what was said, for the logs.
    var logName: String {
        switch self {
        case .pause: return "pause"
        case .resume: return "resume"
        case .meetingMode(let on): return on ? "meetingMode(on)" : "meetingMode(off)"
        case .demoMode(let on): return on ? "demoMode(on)" : "demoMode(off)"
        case .forgetLastHour: return "forgetLastHour"
        case .memoryQuestion: return "memoryQuestion"
        case .toolCommand: return "toolCommand"
        case .didYouMean(let candidates): return "didYouMean(\(candidates.map(\.logName).joined(separator: "|")))"
        }
    }

    /// How Jarvis names a control when asking about it.
    var spoken: String {
        switch self {
        case .pause: return "pause"
        case .resume: return "resume"
        case .meetingMode(let on): return on ? "meeting mode on" : "meeting mode off"
        case .demoMode(let on): return on ? "demo mode on" : "demo mode off"
        case .forgetLastHour: return "forget the last hour"
        case .memoryQuestion, .toolCommand, .didYouMean: return logName
        }
    }

    var isBuiltInControl: Bool {
        switch self {
        case .pause, .resume, .meetingMode, .demoMode, .forgetLastHour: return true
        case .memoryQuestion, .toolCommand, .didYouMean: return false
        }
    }
}

/// "Forget the last hour" as a two-phase command: the draft is the read-back, the yes deletes.
/// The window is fixed when it is read back, so a yes deletes exactly the hour that was named.
/// "Did you mean …?" as a two-phase command: the question is the read-back, and only the yes runs the control.
private final class ControlRunner: CommandRunner {
    private let question: String
    private let run: @MainActor () -> String

    init(question: String, run: @escaping @MainActor () -> String) {
        self.question = question
        self.run = run
    }

    func draft(_ command: String) async throws -> String { question }
    func execute(_ draft: String) async throws -> String { await run() }
}

private final class ForgetRunner: CommandRunner {
    private let forget: ForgetLastHour
    private let clock: any TimeSource
    private var readBackAt: Date?

    init(forget: ForgetLastHour, clock: any TimeSource) {
        self.forget = forget
        self.clock = clock
    }

    func draft(_ command: String) async throws -> String {
        let now = clock.now
        readBackAt = now
        return try forget.describe(now: now)
    }

    func execute(_ draft: String) async throws -> String {
        _ = try forget.perform(now: readBackAt ?? clock.now)
        return "Forgotten."
    }
}
