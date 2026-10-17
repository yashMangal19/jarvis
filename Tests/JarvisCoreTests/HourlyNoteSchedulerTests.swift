import Foundation
import Testing
import JarvisCore

/// Echoes what it was given, so a test can see the prompt and transcript that reached it.
final class HNSEchoNoteWriter: NoteWriter {
    private(set) var calls = 0
    func note(from transcript: String, prompt: String) async throws -> String {
        calls += 1
        return "PROMPT:\(prompt)\nTRANSCRIPT:\(transcript)"
    }
}

final class HNSClock: TimeSource {
    var now: Date
    init(_ now: Date) { self.now = now }
}

final class HNSSleepGuard: SleepGuard {
    func hold() {}
    func release() {}
}

@Suite struct HourlyNoteSchedulerTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-\(UUID().uuidString)")
    var paths: JarvisPaths { JarvisPaths(root: root) }
    /// The device zone: gap markers are written in it, so ids and markers agree.
    let calendar = Calendar.current
    let echo = HNSEchoNoteWriter()

    func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 17,
                                           hour: hour, minute: minute, second: second))!
    }

    func makeScheduler(session: ListeningSession? = nil,
                       writer: (() -> (any NoteWriter)?)? = nil) -> HourlyNoteScheduler {
        let echo = self.echo
        return HourlyNoteScheduler(
            transcripts: TranscriptStore(paths: paths, calendar: calendar),
            session: session ?? ListeningSession(clock: HNSClock(at(9)), sleepGuard: HNSSleepGuard()),
            writer: writer ?? { echo },
            prompts: PromptStore(paths: paths),
            notes: NoteStore(paths: paths, calendar: calendar),
            calendar: calendar)
    }

    func say(_ text: String, at time: Date) throws {
        try TranscriptStore(paths: paths, calendar: calendar)
            .append(TranscriptLine(time: time, label: .me, text: text))
    }

    func hourlyFile(_ id: String) -> URL { paths.notesHourly.appending(path: "\(id).md") }

    @Test func tickWritesTheLastCompletedHourFromItsLines() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try say("Ship it Friday.", at: at(10, 15))

        try await makeScheduler().tick(now: at(11, 5))

        let text = try String(contentsOf: hourlyFile("2026-10-17-10"), encoding: .utf8)
        #expect(text.contains("TRANSCRIPT:10:15 Me: Ship it Friday."))
    }

    @Test func aSecondTickInTheSameHourNeverRewritesTheNote() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try say("Ship it Friday.", at: at(10, 15))
        let scheduler = makeScheduler()
        try await scheduler.tick(now: at(11, 5))
        try say("Late line.", at: at(10, 59))

        try await scheduler.tick(now: at(11, 30))

        #expect(echo.calls == 1)
        let text = try String(contentsOf: hourlyFile("2026-10-17-10"), encoding: .utf8)
        #expect(!text.contains("Late line."))
    }

    @Test func theHoursGapMarkersAreAppendedUnderGaps() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = HNSClock(at(10))
        let session = ListeningSession(clock: clock, sleepGuard: HNSSleepGuard())
        session.start()
        clock.now = at(10, 20)
        session.pause(.user)
        clock.now = at(10, 30)
        session.resume()
        try say("Ship it Friday.", at: at(10, 15))

        try await makeScheduler(session: session).tick(now: at(11, 5))

        let text = try String(contentsOf: hourlyFile("2026-10-17-10"), encoding: .utf8)
        #expect(text.hasSuffix("Ship it Friday.\n\n## Gaps\n- 10:20–10:30: not listening (paused)\n"))
    }

    @Test func demoModeWritesTheLastCompletedTwoMinutes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ListeningSession(clock: HNSClock(at(10)), sleepGuard: HNSSleepGuard())
        session.modes.demoMode = true
        try say("Earlier slot.", at: at(10, 3, 59))
        try say("Demo line.", at: at(10, 5, 10))
        try say("Current slot.", at: at(10, 6, 1))

        try await makeScheduler(session: session).tick(now: at(10, 6, 30))

        let text = try String(contentsOf: hourlyFile("2026-10-17-1004"), encoding: .utf8)
        #expect(text.contains("TRANSCRIPT:10:05 Me: Demo line.\n"))
        #expect(!text.contains("slot."))
    }

    @Test func anHourWithoutSpeechWritesNoNote() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try say("Outside the hour.", at: at(11, 1))

        try await makeScheduler().tick(now: at(11, 5))

        #expect(echo.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: hourlyFile("2026-10-17-10").path))
    }

    @Test func noNoteWriterInstalledSkipsQuietlyAndKeepsTranscripts() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try say("Ship it Friday.", at: at(10, 15))

        try await makeScheduler(writer: { nil }).tick(now: at(11, 5))

        #expect(!FileManager.default.fileExists(atPath: hourlyFile("2026-10-17-10").path))
        let hour = DateInterval(start: at(10), end: at(11))
        #expect(try TranscriptStore(paths: paths, calendar: calendar).lines(in: hour).count == 1)
    }

    @Test func theHourlyPromptIsSeededAndTheUsersEditReachesTheWriter() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let promptFile = paths.prompts.appending(path: "hourly.md")
        try say("First.", at: at(9, 15))
        try say("Second.", at: at(10, 15))
        let scheduler = makeScheduler()

        try await scheduler.tick(now: at(10, 5))
        let seeded = try String(contentsOf: promptFile, encoding: .utf8)
        #expect(seeded.contains("## Decisions"))
        try "Write the word PINEAPPLE.".write(to: promptFile, atomically: true, encoding: .utf8)
        try await scheduler.tick(now: at(11, 5))

        let text = try String(contentsOf: hourlyFile("2026-10-17-10"), encoding: .utf8)
        #expect(text.contains("PROMPT:Write the word PINEAPPLE.\n"))
    }

    @Test func writeNoteForAPastHourWorksWithoutTick() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try say("Voice memo.", at: at(7, 40))

        let url = try await makeScheduler().writeNote(for: DateInterval(start: at(7), end: at(8)))

        #expect(url == hourlyFile("2026-10-17-07"))
        let note = NoteStore(paths: paths, calendar: calendar).note(id: "2026-10-17-07")
        #expect(note?.period == DateInterval(start: at(7), end: at(8)))
        #expect(note?.body.contains("TRANSCRIPT:07:40 Me: Voice memo.") == true)
    }
}
