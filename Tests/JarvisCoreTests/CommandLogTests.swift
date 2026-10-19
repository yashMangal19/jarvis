import Foundation
import Testing
@testable import JarvisCore

/// J-016: `logs/commands.jsonl`, one record per voice command, readable by the user and kept like transcripts.
@MainActor
@Suite struct CommandLogTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-cmdlog-\(UUID().uuidString)")
    var paths: JarvisPaths { JarvisPaths(root: root) }
    let now = Date(timeIntervalSince1970: 1_792_400_000)

    func record(_ time: Date, _ heard: String = "meeting mode off") -> CommandRecord {
        CommandRecord(time: time, trigger: "wake word", mic: "AirPods Pro", heard: heard, intent: "meetingMode(off)",
                      action: "meeting mode off", said: ["Meeting mode off."], outcome: .done)
    }

    @Test func aRecordIsAppendedAndReadBackWhole() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let log = CommandLog(paths: paths)
        try log.append(record(now))
        try log.append(record(now.addingTimeInterval(60), "what did we decide"))

        #expect(try log.records() == [record(now), record(now.addingTimeInterval(60), "what did we decide")])
        #expect(paths.commandLog.path.hasPrefix(paths.root.path + "/logs/"))  // inside the data home: --purge removes it
    }

    @Test func recordsOlderThanSevenDaysExpireLikeTranscripts() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let log = CommandLog(paths: paths)
        let day: TimeInterval = 86_400
        try log.append(record(now.addingTimeInterval(-9 * day)))
        try log.append(record(now.addingTimeInterval(-6 * day)))
        try log.append(record(now))

        try log.purge(olderThan: 7, now: now)

        #expect(try log.records().map(\.time) == [now.addingTimeInterval(-6 * day), now])
    }

    @Test func maintenancePurgesTheCommandLogToo() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let log = CommandLog(paths: paths)
        try log.append(record(now.addingTimeInterval(-9 * 86_400)))
        let notes = NoteStore(paths: paths)
        let maintenance = LaunchMaintenance(transcripts: TranscriptStore(paths: paths),
                                            rollups: RollupScheduler(notes: notes, writer: { nil }, prompts: PromptStore(paths: paths)),
                                            commandLog: log)

        _ = await maintenance.run(now: now)

        #expect(try log.records().isEmpty)
    }

    @Test func forgetTheLastHourRemovesTheRecordsInItsWindow() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let log = CommandLog(paths: paths)
        try log.append(record(now.addingTimeInterval(-2 * 3600)))
        try log.append(record(now.addingTimeInterval(-600)))
        let notes = NoteStore(paths: paths)
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        let forget = ForgetLastHour(transcripts: TranscriptStore(paths: paths), notes: notes, index: index, commandLog: log)

        _ = try forget.perform(now: now)

        #expect(try log.records().map(\.time) == [now.addingTimeInterval(-2 * 3600)])
    }

    // The router writes one record per command, when it ends.

    final class Runner: CommandRunner {
        func draft(_ command: String) async throws -> String { "I will \(command)." }
        func execute(_ draft: String) async throws -> String { "Done." }
    }

    func router() -> (VoiceControlRouter, CommandLog, ListeningSession) {
        let clock = SessionTestClock(now)
        let session = ListeningSession(clock: clock, sleepGuard: SessionTestSleepGuard())
        session.start()
        let notes = NoteStore(paths: paths)
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        let search = MemorySearch(index: index, notes: notes, writer: { MemoryRecordingWriter() }, prompts: PromptStore(paths: paths))
        let log = CommandLog(paths: paths)
        let runner = Runner()
        let commands = CommandSession(runner: { runner }, clock: clock, speak: { _ in })
        let router = VoiceControlRouter(session: session, search: search,
                                        forget: ForgetLastHour(transcripts: TranscriptStore(paths: paths), notes: notes, index: index),
                                        commands: commands, speak: { _ in }, onAnswer: { _ in }, clock: clock, commandLog: log)
        return (router, log, session)
    }

    @Test func aControlIsRecordedWithWhatWasHeardAndSaid() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (router, log, _) = router()

        await router.handle("Jarvis, meeting mode off")

        let records = try log.records()
        #expect(records.count == 1)
        #expect(records.first?.heard == "Jarvis, meeting mode off")
        #expect(records.first?.intent == "meetingMode(off)")
        #expect(records.first?.said == ["Meeting mode off."])
        #expect(records.first?.outcome == .done)
        #expect(records.first?.trigger == "wake word")
    }

    /// QA-27, J-021: a near miss of a control is asked about, never sent to Claude, and recorded as such.
    @Test func aMisheardControlIsAskedAboutAndActedOnOnlyOnYes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (router, log, session) = router()
        session.modes.meetingMode = true

        await router.handle("Jarvis, meeting mode of")
        #expect(session.modes.meetingMode)
        await router.heardReply("yes")

        #expect(!session.modes.meetingMode)
        let record = try #require(try log.records().first)
        #expect(record.intent == "didYouMean(meetingMode(off))")
        #expect(record.said == ["Did you mean meeting mode off?", "Meeting mode off."])
        #expect(record.replies == ["yes"])
        #expect(record.outcome == .done)
    }

    @Test func aMisheardControlAnsweredNoChangesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (router, log, session) = router()

        await router.handle("Jarvis, meeting mode of")  // Meeting mode is off, so "on" is the one that changes something
        await router.heardReply("no")

        #expect(!session.modes.meetingMode)
        let record = try #require(try log.records().first)
        #expect(record.said == ["Did you mean meeting mode on?", "Cancelled."])
        #expect(record.outcome == .cancelled)
    }

    @Test func aConfirmedToolCommandIsRecordedOnceItsResultIsIn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (router, log, _) = router()

        await router.handle("Jarvis, create a file")
        #expect(try log.records().isEmpty)  // still waiting for the yes
        await router.heardReply("yes")

        let record = try #require(try log.records().first)
        #expect(record.said == ["I will create a file.", "Done."])
        #expect(record.replies == ["yes"])
        #expect(record.outcome == .done)
    }

    @Test func aControlDuringAReadBackEndsThePendingCommandAsCancelled() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (router, log, _) = router()

        await router.handle("Jarvis, create a file")
        await router.heardReply("pause")

        let records = try log.records()
        #expect(records.map(\.intent) == ["toolCommand", "pause"])
        #expect(records.first?.outcome == .cancelled)
        #expect(records.first?.reason == "interrupted by a control")
        #expect(records.last?.outcome == .done)
    }
}
