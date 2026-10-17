import Foundation
import Testing
import JarvisCore

@Suite struct LaunchMaintenanceTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-\(UUID().uuidString)")
    var paths: JarvisPaths { JarvisPaths(root: root) }
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }()

    func at(_ day: Int, _ hour: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    @Test func purgesEightDayOldTranscriptKeepsThatDaysNoteAndRollsUp() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let transcripts = TranscriptStore(paths: paths, calendar: Self.calendar)
        let notes = NoteStore(paths: paths, calendar: Self.calendar)
        try transcripts.append(TranscriptLine(time: at(9, 10), label: .me, text: "Old words."))
        let hour = DateInterval(start: at(9, 10), duration: 3600)
        try notes.write(Note(kind: .hourly, id: notes.id(.hourly, period: hour), period: hour, body: "Old note."))
        let writer = HNSEchoNoteWriter()
        let rollups = RollupScheduler(notes: notes, writer: { writer },
                                      prompts: PromptStore(paths: paths), calendar: Self.calendar)

        await LaunchMaintenance(transcripts: transcripts, rollups: rollups).run(now: at(17, 9))

        #expect(!FileManager.default.fileExists(atPath: paths.transcripts.appending(path: "2026-10-09.jsonl").path))
        #expect(notes.note(id: "2026-10-09-10")?.body == "Old note.")
        #expect(notes.note(id: "2026-10-09")?.body.contains("Old note.") == true)
    }
}
