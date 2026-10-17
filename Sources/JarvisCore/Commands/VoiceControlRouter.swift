import Foundation

/// Routes what was heard after the wake word: built-in controls act on the session directly, memory
/// questions are answered from notes, and everything else goes through the confirmation loop.
/// Works while Paused, so nothing is stored; does nothing while Stopped.
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
        switch intent {
        case .pause:
            session.pause(.voice)
            speak("Paused.")
        case .resume:
            session.resume()
            speak("Listening.")
        case .meetingMode(let on):
            session.modes.meetingMode = on
            speak(on ? "Meeting mode on." : "Meeting mode off.")
        case .demoMode(let on):
            session.modes.demoMode = on
            speak(on ? "Demo mode on." : "Demo mode off.")
        case .forgetLastHour:
            await commands.submit("forget the last hour", runner: ForgetRunner(forget: forget, clock: clock))
        case .memoryQuestion(let question):
            do {
                let answer = try await search.answer(question)
                speak(answer.text)
                onAnswer(answer)
            } catch {
                speak("I couldn't search my notes.")
            }
        case .toolCommand(let command):
            await commands.submit(command)
        }
    }

    /// A reply to a pending read-back goes to the confirmation loop; anything else is a new utterance.
    public func heardReply(_ text: String) async {
        if case .stopped = session.state { return }
        if case .awaitingConfirmation = commands.phase {
            await commands.heard(text)
        } else {
            await handle(text)
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
