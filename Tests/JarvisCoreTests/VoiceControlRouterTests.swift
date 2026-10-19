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

/// Runs `during` while the answer is being written, then throws `error` or returns the answer.
private final class RouterScriptedWriter: NoteWriter {
    var during: () -> Void = {}
    var error: Error?
    func note(from transcript: String, prompt: String) async throws -> String {
        during()
        if let error { throw error }
        return "You cut the travel line (2026-10-17-09)."
    }
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

    private func make(state: ListeningState = .listening,
                      writer: any NoteWriter = MemoryRecordingWriter()) -> Fixture {
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

    // J-021: a near miss never reaches the command runner (Claude), whatever the reply.
    @Test func aNearMissNeverAsksTheCommandRunner() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make()
        f.session.modes.meetingMode = true

        await f.router.handle("Jarvis, turn meeting mode off")
        await f.router.heardReply("yes")
        await f.router.handle("Jarvis, demo mode onn")
        await f.router.heardReply("no")

        #expect(log.runnerRequests == 0)
        #expect(runner.drafts.isEmpty && runner.executed.isEmpty)
        #expect(!f.session.modes.meetingMode && !f.session.modes.demoMode)
        #expect(log.spoken == ["Did you mean meeting mode off?", "Meeting mode off.", "Did you mean demo mode on?", "Cancelled."])
    }

    // J-027, QA-22's two utterances as heard. Neither reaches the command runner.
    @Test func qa22BossIsAskedAboutAndPauseResumeRunsInOrder() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make()

        await f.router.handle("Jarvis, boss.")
        #expect(log.spoken == ["Did you mean pause?"])
        await f.router.heardReply("yes")
        #expect(f.session.state == .paused(.voice))

        await f.router.handle("pause, Jarvis, resume.")
        #expect(f.session.state == .listening)
        #expect(log.spoken == ["Did you mean pause?", "Paused.", "Paused.", "Listening."])
        #expect(log.runnerRequests == 0 && runner.drafts.isEmpty)
    }

    @Test func oneUnknownWordIsNotActedOnAndNeverReachesTheRunner() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make()

        await f.router.handle("Jarvis, hello")

        #expect(log.spoken == ["Sorry, I didn't catch that."])
        #expect(log.runnerRequests == 0)
        #expect(f.session.state == .listening)
    }

    @Test func stopCancelsAWaitingReadBack() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make()

        await f.router.handle("Jarvis, create a file")
        await f.router.heardReply("Jarvis, stop")

        #expect(f.commands.phase == .idle || f.commands.phase == .cancelled(.declined))
        #expect(runner.executed.isEmpty)
        #expect(log.spoken.last == "Cancelled.")
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

    // Paused: a memory question is answered aloud and handed to the panel.
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
        #expect(log.runnerRequests == 0)
    }

    private var budgetNote: Note {
        Note(kind: .hourly, id: "2026-10-17-09", period: DateInterval(start: clock.now, duration: 3600),
             body: "Budget review: we cut the travel line")
    }

    // F-5: a cancelled search ends quietly, like a cancelled command.
    @Test func aCancelledMemorySearchSaysNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = RouterScriptedWriter()
        writer.error = CancellationError()
        let f = make(writer: writer)
        try f.notes.write(budgetNote)

        await f.router.handle("Jarvis, what did we decide about the budget?")

        #expect(log.spoken.isEmpty)
        #expect(log.answers.isEmpty)
    }

    // F-5: Stop said while the answer is being written wins; the answer is neither spoken nor shown.
    @Test func aStopDuringTheMemorySearchDropsTheAnswer() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = RouterScriptedWriter()
        let f = make(writer: writer)
        writer.during = { f.session.stop(.user) }
        try f.notes.write(budgetNote)

        await f.router.handle("Jarvis, what did we decide about the budget?")

        #expect(log.spoken.isEmpty)
        #expect(log.answers.isEmpty)
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

    // F-H1, DEC-22 (story 8a): a held command routes while Stopped. Its read-back is answered by holding
    // again, since the mic runs only for a hold; a held question is answered aloud.
    @Test(arguments: [StopReason.user, .screenLock, .quietHours])
    func aHeldCommandRoutesWhileStopped(reason: StopReason) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make(state: .stopped(reason))
        try f.notes.write(budgetNote)

        await f.router.handleHeld("email Asha the deck")
        #expect(log.spoken == ["plan: email Asha the deck"])
        await f.router.handleHeld("Yes.")
        #expect(runner.executed == ["plan: email Asha the deck"])
        #expect(log.spoken.last == "Done.")

        await f.router.handleHeld("what did we decide about the budget?")
        #expect(log.spoken.last == "You cut the travel line (2026-10-17-09).")
        #expect(log.answers.map(\.usedNoteIDs) == [["2026-10-17-09"]])
        #expect(f.session.state == .stopped(reason))
    }

    // F-1: once the read-back has timed out, what is heard next is a new utterance, not a lost reply.
    @Test func aReplyAfterTheReadBackTimedOutIsRoutedAsANewUtterance() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make()

        await f.router.handle("Jarvis, email Asha the deck")
        clock.now = clock.now.addingTimeInterval(16)
        await f.router.heardReply("Jarvis, email Ravi")

        #expect(runner.drafts == ["email Asha the deck", "email Ravi"])
        #expect(runner.executed.isEmpty)
        #expect(log.spoken == ["plan: email Asha the deck", "plan: email Ravi"])
        #expect(f.commands.phase == .awaitingConfirmation(draft: "plan: email Ravi", corrections: 0))
    }

    // F-2 (decision): a built-in control said during a read-back cancels the command, says so, then runs.
    @Test func aControlDuringAReadBackCancelsTheCommandThenRuns() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make()

        await f.router.handle("Jarvis, email Asha the deck")
        await f.router.heardReply("Jarvis, pause listening.")

        #expect(f.session.state == .paused(.voice))
        #expect(log.spoken == ["plan: email Asha the deck", "Cancelled.", "Paused."])
        #expect(runner.drafts == ["email Asha the deck"])
        #expect(f.commands.phase == .idle)

        await f.router.heardReply("yes")
        #expect(runner.executed.isEmpty)
    }

    @Test func anythingElseDuringAReadBackIsACorrection() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make()

        await f.router.handle("Jarvis, email Asha the deck")
        await f.router.heardReply("send it to Ravi instead")

        #expect(runner.drafts == ["email Asha the deck",
                                  "email Asha the deck\nCorrections so far:\n- send it to Ravi instead"])
        #expect(f.session.state == .listening)
    }

    // F-6 (decision): voice resume is honoured after the headset drops; it says the MacBook mic is in use,
    // and the headset is picked up again when it reconnects.
    @Test func resumeAfterTheHeadsetDropsListensThroughTheMacBookMic() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make()
        let headset = InputDevice(name: "AirPods", isBluetoothHeadset: true)
        let builtIn = InputDevice(name: "MacBook Pro Microphone", isBluetoothHeadset: false)
        f.session.handle(.inputChanged(headset))
        f.session.handle(.inputLost(headset))
        f.session.handle(.inputChanged(builtIn))
        #expect(f.session.state == .paused(.routeLost))

        await f.router.handle("Jarvis, resume")

        #expect(f.session.state == .listening)
        #expect(f.session.input == builtIn)
        #expect(log.spoken == ["Listening through the MacBook mic."])

        f.session.handle(.inputChanged(headset))
        #expect(f.session.state == .listening)
        #expect(f.session.input == headset)
    }

    @Test func aReplyWithNothingPendingIsANewUtterance() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let f = make()

        await f.router.heardReply("Jarvis, demo mode on")

        #expect(f.session.modes.demoMode == true)
    }
}
