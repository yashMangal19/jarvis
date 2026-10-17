import Foundation

/// Routes what was heard after the wake word: built-in controls act on the session directly, memory
/// questions are answered from notes, and everything else goes through the confirmation loop.
/// Works while Paused (nothing heard is stored then; `ListeningSession.storesMemory` gates that in the
/// capture pipeline, not here); does nothing while Stopped.
@MainActor
public final class VoiceControlRouter {
    private let session: ListeningSession
    private let search: MemorySearch
    private let forget: ForgetLastHour
    private let commands: CommandSession
    private let speak: (String) -> Void
    private let onAnswer: (MemoryAnswer) -> Void
    private let clock: any TimeSource

    public init(session: ListeningSession, search: MemorySearch, forget: ForgetLastHour, commands: CommandSession,
                speak: @escaping (String) -> Void, onAnswer: @escaping (MemoryAnswer) -> Void, clock: any TimeSource) {
        self.session = session
        self.search = search
        self.forget = forget
        self.commands = commands
        self.speak = speak
        self.onAnswer = onAnswer
        self.clock = clock
    }

    public func handle(_ utterance: String) async {
        if case .stopped = session.state { return }
        guard let intent = VoiceIntentParser.parse(utterance) else { return }
        await act(on: intent)
    }

    /// A reply to a pending read-back goes to the confirmation loop, unless it is a built-in control:
    /// then the pending command is cancelled aloud and the control runs. Anything else is a new utterance.
    /// The timeout is applied first, so a read-back that went unanswered does not swallow what comes next.
    public func heardReply(_ text: String) async {
        if case .stopped = session.state { return }
        commands.tick(now: clock.now)
        guard case .awaitingConfirmation = commands.phase else { return await handle(text) }
        if let intent = VoiceIntentParser.parse(text), intent.isBuiltInControl {
            commands.reset()
            speak("Cancelled.")
            await act(on: intent)
        } else {
            await commands.heard(text)
        }
    }

    private func act(on intent: VoiceIntent) async {
        switch intent {
        case .pause:
            session.pause(.voice)
            speak("Paused.")
        case .resume:
            // A route-lost pause is ended by voice too: capture carries on from the MacBook mic, and the
            // headset is picked up again when it reconnects.
            let headsetWasLost = session.state == .paused(.routeLost)
            session.resume()
            speak(headsetWasLost ? "Listening through the MacBook mic." : "Listening.")
        case .meetingMode(let on):
            session.modes.meetingMode = on
            speak(on ? "Meeting mode on." : "Meeting mode off.")
        case .demoMode(let on):
            session.modes.demoMode = on
            speak(on ? "Demo mode on." : "Demo mode off.")
        case .forgetLastHour:
            await commands.submit("forget the last hour", runner: ForgetRunner(forget: forget, clock: clock))
        case .memoryQuestion(let question):
            // A Stop said while the answer is written wins, and a cancelled search ends quietly.
            do {
                let answer = try await search.answer(question)
                if case .stopped = session.state { return }
                speak(answer.text)
                onAnswer(answer)
            } catch is CancellationError {
            } catch {
                if case .stopped = session.state { return }
                speak("I couldn't search my notes.")
            }
        case .toolCommand(let command):
            await commands.submit(command)
        }
    }
}

private extension VoiceIntent {
    var isBuiltInControl: Bool {
        switch self {
        case .pause, .resume, .meetingMode, .demoMode, .forgetLastHour: return true
        case .memoryQuestion, .toolCommand: return false
        }
    }
}

/// "Forget the last hour" as a two-phase command: the draft is the read-back, the yes deletes.
/// The window is fixed when it is read back, so a yes deletes exactly the hour that was named.
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
