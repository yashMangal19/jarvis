import Foundation
import Testing
import JarvisCore

/// Records every request; drafts are "plan: <request>", results are "Sent.".
private final class ScriptedCommandRunner: CommandRunner {
    var drafts: [String] = []
    var executed: [String] = []
    var executeError: Error?
    var draftError: Error?

    func draft(_ command: String) async throws -> String {
        drafts.append(command)
        if let draftError { throw draftError }
        return "plan: \(command)"
    }

    func execute(_ draft: String) async throws -> String {
        executed.append(draft)
        if let executeError { throw executeError }
        return "Sent."
    }
}

private final class CommandTestClock: TimeSource {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

@MainActor
@Suite struct CommandSessionTests {
    private let runner = ScriptedCommandRunner()
    private let clock = CommandTestClock()
    private let spoken = CommandSpokenLog()

    func makeSession() -> CommandSession {
        let runner = self.runner, spoken = self.spoken
        return CommandSession(runner: { runner }, clock: clock, speak: { spoken.lines.append($0) })
    }

    // QA-66: a read-back with no reply never acts.
    @Test func submitReadsBackTheDraftAndDoesNotExecute() async {
        let session = makeSession()
        await session.submit("email Asha the deck")

        #expect(session.phase == .awaitingConfirmation(draft: "plan: email Asha the deck", corrections: 0))
        #expect(spoken.lines == ["plan: email Asha the deck"])
        #expect(runner.drafts == ["email Asha the deck"])
        #expect(runner.executed.isEmpty)
    }

    // Story 28/31: a yes (any phrasing, any case, with punctuation) executes the read-back draft.
    @Test(arguments: ["Yes.", "  okay ", "Go ahead!", "do it", "Haan", "yup", "confirm", "go-ahead", "Do-it."])
    func yesExecutesTheDraftAndSpeaksTheResult(reply: String) async {
        let session = makeSession()
        await session.submit("email Asha the deck")
        await session.heard(reply)

        #expect(runner.executed == ["plan: email Asha the deck"])
        #expect(session.phase == .finished(result: "Sent."))
        #expect(spoken.lines.last == "Sent.")
    }

    // Story 29: a bare "no" cancels and says so; nothing is executed.
    @Test(arguments: ["No.", "nope", "Cancel", "nahi", "Don't!", "stop", "nah"])
    func bareNoCancels(reply: String) async {
        let session = makeSession()
        await session.submit("email Asha the deck")
        await session.heard(reply)

        #expect(session.phase == .cancelled(.declined))
        #expect(spoken.lines.last == "Cancelled.")
        #expect(runner.executed.isEmpty)
    }

    // QA-71 / story 29a: anything else is a correction — redraft with it, read back again.
    @Test func correctionRedraftsAndReadsBackAgain() async {
        let session = makeSession()
        await session.submit("email Asha the deck")
        await session.heard("no, send it to Prashant instead")

        let request = "email Asha the deck\nCorrections so far:\n- no, send it to Prashant instead"
        #expect(runner.drafts.last == request)
        #expect(session.phase == .awaitingConfirmation(draft: "plan: \(request)", corrections: 1))
        #expect(spoken.lines.last == "plan: \(request)")
        #expect(runner.executed.isEmpty)
    }

    // QA-72: the third correction without a yes drops the command and says so.
    @Test func thirdCorrectionDropsTheCommand() async {
        let session = makeSession()
        await session.submit("email Asha the deck")
        await session.heard("to Prashant")
        await session.heard("attach the PDF")

        #expect(runner.drafts.last == "email Asha the deck\nCorrections so far:\n- to Prashant\n- attach the PDF")

        await session.heard("and cc Ravi")

        #expect(session.phase == .cancelled(.tooManyCorrections))
        #expect(spoken.lines.last == "Dropping it — three corrections without a yes.")
        #expect(runner.drafts.count == 3)
        #expect(runner.executed.isEmpty)
    }

    // Story 29 / QA-70: 15 s of silence cancels without a word; a yes after that does nothing.
    @Test func silenceTimesOutQuietlyAndALateYesDoesNothing() async {
        let session = makeSession()
        await session.submit("email Asha the deck")

        clock.now += 14.9
        session.tick(now: clock.now)
        #expect(session.phase == .awaitingConfirmation(draft: "plan: email Asha the deck", corrections: 0))

        clock.now += 5.1
        session.tick(now: clock.now)
        await session.heard("yes")

        #expect(session.phase == .cancelled(.timeout))
        #expect(spoken.lines == ["plan: email Asha the deck"])
        #expect(runner.executed.isEmpty)
    }

    // A yes arriving after 15 s is not a yes, even if no tick ran in between.
    @Test func lateYesWithoutATickStillTimesOut() async {
        let session = makeSession()
        await session.submit("email Asha the deck")
        clock.now += 20
        await session.heard("yes")

        #expect(session.phase == .cancelled(.timeout))
        #expect(spoken.lines == ["plan: email Asha the deck"])
        #expect(runner.executed.isEmpty)
    }

    // Each read-back restarts the 15 s window.
    @Test func redraftRestartsTheReplyWindow() async {
        let session = makeSession()
        await session.submit("email Asha the deck")
        clock.now += 10
        await session.heard("to Prashant")
        clock.now += 10
        session.tick(now: clock.now)
        await session.heard("yes")

        #expect(runner.executed.count == 1)
        #expect(session.phase == .finished(result: "Sent."))
    }

    // Commands engine off (D-4: nil means off) — say why, do nothing.
    @Test func noRunnerSaysCommandsNeedClaudeCode() async {
        let spoken = self.spoken
        let session = CommandSession(runner: { nil }, clock: clock, speak: { spoken.lines.append($0) })
        await session.submit("email Asha the deck")

        #expect(session.phase == .cancelled(.failed("Commands need Claude Code.")))
        #expect(spoken.lines == ["Commands need Claude Code."])
    }

    // A failed execute is spoken and ends the command.
    @Test func executeFailureIsSpokenAndCancels() async {
        runner.executeError = CommandTestError(message: "Mail is not connected.")
        let session = makeSession()
        await session.submit("email Asha the deck")
        await session.heard("yes")

        #expect(session.phase == .cancelled(.failed("Mail is not connected.")))
        #expect(spoken.lines.last == "Mail is not connected.")
    }

    // A failed draft is spoken and ends the command; nothing is read back for confirmation.
    @Test func draftFailureIsSpokenAndCancels() async {
        runner.draftError = CommandTestError(message: "Claude Code is not signed in.")
        let session = makeSession()
        await session.submit("email Asha the deck")

        #expect(session.phase == .cancelled(.failed("Claude Code is not signed in.")))
        #expect(spoken.lines == ["Claude Code is not signed in."])
        #expect(runner.executed.isEmpty)
    }

    // A per-command runner drafts, redrafts and executes that command.
    @Test func perCommandRunnerIsUsedThroughout() async {
        let other = ScriptedCommandRunner()
        let session = makeSession()
        await session.submit("forget the last hour", runner: other)
        await session.heard("only the last ten minutes")
        await session.heard("yes")

        #expect(other.drafts.count == 2)
        #expect(other.executed.count == 1)
        #expect(runner.drafts.isEmpty && runner.executed.isEmpty)
    }

    // F-5: the drop message and threshold follow `maxCorrections`.
    @Test func dropMessageFollowsMaxCorrections() async {
        let runner = self.runner, spoken = self.spoken
        let session = CommandSession(runner: { runner }, clock: clock, speak: { spoken.lines.append($0) },
                                     maxCorrections: 2)
        await session.submit("email Asha the deck")
        await session.heard("to Prashant")
        await session.heard("attach the PDF")

        #expect(session.phase == .cancelled(.tooManyCorrections))
        #expect(spoken.lines.last == "Dropping it — two corrections without a yes.")
        #expect(runner.drafts.count == 2)
    }

    // F-5: `>=` — a zero budget drops on the first correction instead of never.
    @Test func zeroMaxCorrectionsDropsOnFirstCorrection() async {
        let runner = self.runner, spoken = self.spoken
        let session = CommandSession(runner: { runner }, clock: clock, speak: { spoken.lines.append($0) },
                                     maxCorrections: 0)
        await session.submit("email Asha the deck")
        await session.heard("to Prashant")

        #expect(session.phase == .cancelled(.tooManyCorrections))
        #expect(runner.drafts.count == 1)
    }

    // F-3: a cancelled execute ends quietly — no framework string spoken, no failure recorded.
    @Test func cancelledExecuteEndsQuietly() async {
        runner.executeError = CancellationError()
        let session = makeSession()
        await session.submit("email Asha the deck")
        await session.heard("yes")

        #expect(session.phase == .idle)
        #expect(spoken.lines == ["plan: email Asha the deck"])
    }

    // F-3: a cancelled draft ends quietly too.
    @Test func cancelledDraftEndsQuietly() async {
        runner.draftError = CancellationError()
        let session = makeSession()
        await session.submit("email Asha the deck")

        #expect(session.phase == .idle)
        #expect(spoken.lines.isEmpty)
    }

    // F-2: a second command arriving while the first is still drafting wins; the late first
    // draft is neither spoken nor confirmable, and a yes runs the second draft on its own runner.
    @Test func secondSubmitWhileFirstDraftIsInFlightWins() async {
        let slow = GatedCommandRunner()
        let fast = ScriptedCommandRunner()
        let session = makeSession()

        let first = Task { await session.submit("email Asha the deck", runner: slow) }
        await slow.waitUntilDrafting()
        await session.submit("forget the last hour", runner: fast)
        slow.finishDraft("plan: email Asha the deck")
        await first.value

        #expect(session.phase == .awaitingConfirmation(draft: "plan: forget the last hour", corrections: 0))
        #expect(spoken.lines == ["plan: forget the last hour"])

        await session.heard("yes")

        #expect(fast.executed == ["plan: forget the last hour"])
        #expect(slow.executed.isEmpty)
        #expect(session.phase == .finished(result: "Sent."))
    }

    // F-2: a reset while execute is in flight is not overwritten by the late result.
    @Test func resetDuringExecuteIsNotOverwritten() async {
        let slow = GatedCommandRunner()
        slow.draftResult = "plan: email Asha the deck"
        let session = makeSession()
        await session.submit("email Asha the deck", runner: slow)

        let yes = Task { await session.heard("yes") }
        await slow.waitUntilExecuting()
        session.reset()
        slow.finishExecute("Sent.")
        await yes.value

        #expect(session.phase == .idle)
        #expect(spoken.lines == ["plan: email Asha the deck"])
    }

    @Test func resetReturnsToIdle() async {
        let session = makeSession()
        await session.submit("email Asha the deck")
        session.reset()
        await session.heard("yes")

        #expect(session.phase == .idle)
        #expect(runner.executed.isEmpty)
    }
}

private struct CommandTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class CommandSpokenLog {
    var lines: [String] = []
}

/// A runner whose `draft` / `execute` suspend until the test releases them.
/// `draftResult` set → `draft` returns it at once instead of suspending.
@MainActor
private final class GatedCommandRunner: CommandRunner {
    var draftResult: String?
    var executed: [String] = []
    private var draftGate: CheckedContinuation<String, Never>?
    private var executeGate: CheckedContinuation<String, Never>?

    func draft(_ command: String) async throws -> String {
        if let draftResult { return draftResult }
        return await withCheckedContinuation { draftGate = $0 }
    }

    func execute(_ draft: String) async throws -> String {
        executed.append(draft)
        return await withCheckedContinuation { executeGate = $0 }
    }

    func waitUntilDrafting() async { while draftGate == nil { await Task.yield() } }
    func waitUntilExecuting() async { while executeGate == nil { await Task.yield() } }
    func finishDraft(_ result: String) { draftGate?.resume(returning: result); draftGate = nil }
    func finishExecute(_ result: String) { executeGate?.resume(returning: result); executeGate = nil }
}
