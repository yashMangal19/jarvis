import Foundation
import Testing
import JarvisCore

@Suite struct RollupSchedulerTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-\(UUID().uuidString)")
    var paths: JarvisPaths { JarvisPaths(root: root) }
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }()
    let echo = HNSEchoNoteWriter()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    var notes: NoteStore { NoteStore(paths: paths, calendar: Self.calendar) }

    func makeScheduler(writer: (() -> (any NoteWriter)?)? = nil) -> RollupScheduler {
        let echo = self.echo
        return RollupScheduler(notes: notes, writer: writer ?? { echo },
                               prompts: PromptStore(paths: paths), calendar: Self.calendar)
    }

    func hourly(_ day: Int, _ hour: Int, _ body: String, minutes: Int = 60) throws {
        let period = DateInterval(start: at(day, hour), duration: Double(minutes * 60))
        try notes.write(Note(kind: .hourly, id: notes.id(.hourly, period: period), period: period, body: body))
    }

    @Test func yesterdaysHourlyNotesBecomeYesterdaysDailyNoteAfterMidnight() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try hourly(16, 10, "Ship it Friday.")
        try hourly(16, 14, "Call Priya.")

        try await makeScheduler().runIfDue(now: at(17, 0, 5))

        let daily = try #require(notes.note(id: "2026-10-16"))
        #expect(daily.kind == .daily)
        #expect(daily.period == DateInterval(start: at(16, 0), end: at(17, 0)))
        #expect(daily.body.hasPrefix("PROMPT:\(try PromptStore(paths: paths).prompt(.daily))"))
        #expect(daily.body.contains("## 2026-10-16-10\nShip it Friday."))
        #expect(daily.body.contains("## 2026-10-16-14\nCall Priya."))
        #expect(daily.body.range(of: "Ship it")!.lowerBound < daily.body.range(of: "Call Priya")!.lowerBound)
    }

    func daily(_ day: Int, _ body: String) throws {
        let period = DateInterval(start: at(day, 0), end: at(day + 1, 0))
        try notes.write(Note(kind: .daily, id: notes.id(.daily, period: period), period: period, body: body))
    }

    @Test func todayAndDaysWithoutHourlyNotesGetNoDailyNote() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try hourly(17, 9, "Still today.")

        try await makeScheduler().runIfDue(now: at(17, 23, 59))

        #expect(notes.allIDs(kind: .daily).isEmpty)
        #expect(echo.calls == 0)
    }

    @Test func demoSlotNotesAreRolledIntoTheirDay() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try hourly(16, 10, "Demo slot.", minutes: 2)

        try await makeScheduler().runIfDue(now: at(17, 1))

        #expect(notes.note(id: "2026-10-16")?.body.contains("## 2026-10-16-1000\nDemo slot.") == true)
    }

    @Test func completedWeekBecomesAWeeklyNoteOnMondayIncludingSundaysNewDaily() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for day in 12...17 { try daily(day, "Day \(day).") }  // Mon 12 … Sat 17
        try hourly(18, 11, "Sunday walk.")

        try await makeScheduler().runIfDue(now: at(18, 23, 59))
        #expect(notes.allIDs(kind: .weekly).isEmpty)

        try await makeScheduler().runIfDue(now: at(19, 0, 5))

        let weekly = try #require(notes.note(id: "2026-W42"))
        #expect(weekly.period == DateInterval(start: at(12, 0), end: at(19, 0)))
        #expect(weekly.body.hasPrefix("PROMPT:\(try PromptStore(paths: paths).prompt(.weekly))"))
        #expect(weekly.body.contains("## 2026-10-12\nDay 12."))
        #expect(weekly.body.contains("## 2026-10-18\nPROMPT:"))
        #expect(weekly.body.contains("Sunday walk."))
    }

    @Test func runningTwiceWritesNothingNew() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try hourly(18, 11, "Sunday walk.")
        try await makeScheduler().runIfDue(now: at(19, 1))
        let calls = echo.calls
        let before = try String(contentsOf: paths.notesWeekly.appending(path: "2026-W42.md"), encoding: .utf8)

        try await makeScheduler().runIfDue(now: at(19, 2))

        #expect(calls == 2)
        #expect(echo.calls == calls)
        #expect(try String(contentsOf: paths.notesWeekly.appending(path: "2026-W42.md"), encoding: .utf8) == before)
    }

    @Test func noWriterSkipsQuietly() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try hourly(16, 10, "Ship it Friday.")

        try await makeScheduler(writer: { nil }).runIfDue(now: at(17, 1))

        #expect(notes.allIDs(kind: .daily).isEmpty)
    }

    @Test func editedDailyPromptIsTheOneUsed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try paths.ensureLayout()
        try "Summarise as haiku.".write(to: paths.prompts.appending(path: "daily.md"), atomically: true, encoding: .utf8)
        try hourly(16, 10, "Ship it Friday.")

        try await makeScheduler().runIfDue(now: at(17, 1))

        #expect(notes.note(id: "2026-10-16")?.body.hasPrefix("PROMPT:Summarise as haiku.") == true)
    }
}
