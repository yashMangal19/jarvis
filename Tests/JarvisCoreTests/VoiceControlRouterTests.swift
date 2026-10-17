import Foundation
import Testing
import JarvisCore

/// Records every request; drafts are "plan: <request>", results are "Done.".
private final class RouterRecordingRunner: CommandRunner {
    var drafts: [String] = []
    var executed: [String] = []
    func draft(_ command: String) async throws -> String { drafts.append(command); return "plan: \(command)" }
    func execute(_ draft: String) async throws -> String { executed.append(draft); return "Done." }
}

private final class RouterLog {
    var spoken: [String] = []
    var answers: [MemoryAnswer] = []
    var runnerRequests = 0
}

@MainActor
@Suite struct VoiceControlRouterTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-\(UUID().uuidString)")
    var paths: JarvisPaths { JarvisPaths(root: root) }
    private let log = RouterLog()
    private let runner = RouterRecordingRunner()
    let clock = SessionTestClock(Date(timeIntervalSince1970: 1_790_000_000))

    private struct Fixture {
        let session: ListeningSession
        let commands: CommandSession
        let router: VoiceControlRouter
        let transcripts: TranscriptStore
        let notes: NoteStore
        let index: NoteIndex
    }

    private func make(state: ListeningState = .listening) -> Fixture {
        let session = ListeningSession(clock: clock, sleepGuard: SessionTestSleepGuard())
        switch state {
        case .listening: session.start()
        case .paused(let reason): session.start(); session.pause(reason)
        case .stopped(let reason): session.stop(reason)
        }
        let transcripts = TranscriptStore(paths: paths)
        let notes = NoteStore(paths: paths)
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        index.attach(to: notes)
        let writer = MemoryRecordingWriter()
        let search = MemorySearch(index: index, notes: notes, writer: { writer }, prompts: PromptStore(paths: paths))
        let forget = ForgetLastHour(transcripts: transcripts, notes: notes, index: index)
        let log = self.log, runner = self.runner
        let commands = CommandSession(runner: { log.runnerRequests += 1; return runner }, clock: clock,
                                      speak: { log.spoken.append($0) })
        let router = VoiceControlRouter(session: session, search: search, forget: forget, commands: commands,
                                        speak: { log.spoken.append($0) }, onAnswer: { log.answers.append($0) },
                                        clock: clock)
        return Fixture(session: session, commands: commands, router: router,
                       transcripts: transcripts, notes: notes, index: index)
    }

    @Test func meetingModeOnSwitchesTheModeAndSaysSo() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make()

        await f.router.handle("Jarvis, meeting mode on")

        #expect(f.session.modes.meetingMode == true)
        #expect(log.spoken == ["Meeting mode on."])
    }

    // Story 8b: every built-in control acts without asking for a command runner.
    @Test func everyControlActsWithoutACommandRunner() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make()

        await f.router.handle("Jarvis, demo mode on")
        #expect(f.session.modes.demoMode == true)
        await f.router.handle("Jarvis, meeting mode on.")
        await f.router.handle("Jarvis, meeting mode off.")
        #expect(f.session.modes.meetingMode == false)
        await f.router.handle("Jarvis, demo mode off")
        #expect(f.session.modes.demoMode == false)
        await f.router.handle("Jarvis, pause listening.")
        #expect(f.session.state == .paused(.voice))
        await f.router.handle("Jarvis, resume")
        #expect(f.session.state == .listening)

        #expect(log.spoken == ["Demo mode on.", "Meeting mode on.", "Meeting mode off.", "Demo mode off.",
                               "Paused.", "Listening."])
        #expect(log.runnerRequests == 0)
        #expect(f.commands.phase == .idle)
    }

    @Test func pauseTheMusicIsAToolCommandAndDoesNotPause() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make()

        await f.router.handle("Jarvis, pause the music")

        #expect(f.session.state == .listening)
        #expect(runner.drafts == ["pause the music"])
        #expect(f.commands.phase == .awaitingConfirmation(draft: "plan: pause the music", corrections: 0))
    }

    // A tool command reaches the confirmation loop and runs only on a yes, while paused too.
    @Test func aToolCommandWhilePausedIsReadBackAndRunsOnYes() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make(state: .paused(.user))

        await f.router.handle("Jarvis, email Asha the deck")
        #expect(log.spoken == ["plan: email Asha the deck"])
        #expect(runner.executed.isEmpty)
        await f.router.heardReply("Yes.")

        #expect(runner.executed == ["plan: email Asha the deck"])
        #expect(log.spoken.last == "Done.")
        #expect(f.session.storesMemory == false)
    }

    // QA-30/31: forget is read back with live counts and nothing is deleted until a yes.
    @Test func forgetTheLastHourIsReadBackAndDeletesOnlyOnYes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make()
        let line = TranscriptLine(time: clock.now.addingTimeInterval(-600), label: .me, text: "Budget is tight.")
        try f.transcripts.append(line)
        let hour = DateInterval(start: clock.now.addingTimeInterval(-600), duration: 3600)

        await f.router.handle("Jarvis, forget the last hour.")

        guard case let .awaitingConfirmation(draft, _) = f.commands.phase else {
            Issue.record("not read back: \(f.commands.phase)"); return
        }
        #expect(draft.hasPrefix("Delete the last hour, "))
        #expect(draft.hasSuffix(": 1 transcript line and 0 notes?"))
        #expect(log.spoken == [draft])
        #expect(try f.transcripts.lines(in: hour) == [line])
        #expect(log.runnerRequests == 0)

        await f.router.heardReply("yes")

        #expect(try f.transcripts.lines(in: hour).isEmpty)
        #expect(log.spoken.last == "Forgotten.")
    }

    @Test func forgetDeclinedDeletesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make()
        let line = TranscriptLine(time: clock.now.addingTimeInterval(-600), label: .me, text: "Budget is tight.")
        try f.transcripts.append(line)

        await f.router.handle("Jarvis, forget last hour")
        await f.router.heardReply("No.")

        #expect(try f.transcripts.lines(in: DateInterval(start: line.time, duration: 60)) == [line])
        #expect(log.spoken.last == "Cancelled.")
    }

    // Paused: a memory question is answered aloud and handed to the panel, and nothing is stored.
    @Test func aMemoryQuestionWhilePausedIsSpokenAndHandedOn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make(state: .paused(.user))
        let note = Note(kind: .hourly, id: "2026-10-17-09", period: DateInterval(start: clock.now, duration: 3600),
                        body: "Budget review: we cut the travel line")
        try f.notes.write(note)

        await f.router.handle("Jarvis, what did we decide about the budget?")

        let expected = MemoryAnswer(text: "You cut the travel line (2026-10-17-09).", usedNoteIDs: ["2026-10-17-09"])
        #expect(log.answers == [expected])
        #expect(log.spoken == [expected.text])
        #expect(f.session.state == .paused(.user))
        #expect(f.session.storesMemory == false)
        #expect(log.runnerRequests == 0)
    }

    @Test(arguments: [StopReason.user, .screenLock, .quietHours])
    func nothingHappensWhileStopped(reason: StopReason) async {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make(state: .stopped(reason))

        for heard in ["Jarvis, resume", "Jarvis, meeting mode on", "Jarvis, what did we decide?",
                      "Jarvis, email Asha", "Jarvis, forget the last hour"] {
            await f.router.handle(heard)
            await f.router.heardReply(heard)
        }

        #expect(f.session.state == .stopped(reason))
        #expect(f.session.modes == Modes())
        #expect(log.spoken.isEmpty)
        #expect(log.answers.isEmpty)
        #expect(log.runnerRequests == 0)
        #expect(f.commands.phase == .idle)
    }

    @Test func aReplyWithNothingPendingIsANewUtterance() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make()

        await f.router.heardReply("Jarvis, demo mode on")

        #expect(f.session.modes.demoMode == true)
    }
}
