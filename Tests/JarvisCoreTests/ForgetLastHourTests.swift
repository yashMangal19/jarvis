import Foundation
import Testing
import JarvisCore

@Suite struct ForgetLastHourTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-\(UUID().uuidString)")
    var paths: JarvisPaths { JarvisPaths(root: root) }

    /// Fixed zone so day files and HH:MM are deterministic wherever the tests run.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    func forgetAt(_ hour: Int, _ minute: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: hour, minute: minute))!
    }

    @Test func performLeavesNothingOfTheHourInTranscriptsNotesOrIndex() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let transcripts = TranscriptStore(paths: paths, calendar: Self.calendar)
        let notes = NoteStore(paths: paths, calendar: Self.calendar)
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        let now = forgetAt(14, 5)
        try transcripts.append(TranscriptLine(time: forgetAt(13, 30), label: .me, text: "Budget is tight."))
        let hour = DateInterval(start: forgetAt(13), end: forgetAt(14))
        let note = Note(kind: .hourly, id: notes.id(.hourly, period: hour), period: hour, body: "Budget talk")
        try notes.write(note)
        try index.add(noteID: note.id, text: note.body)
        let forget = ForgetLastHour(transcripts: transcripts, notes: notes, index: index, calendar: Self.calendar)

        let report = try forget.perform(now: now)

        #expect(report.linesDeleted == 1)
        #expect(report.noteIDs == [note.id])
        #expect(try transcripts.lines(in: forget.window(now: now)).isEmpty)
        #expect(notes.note(id: note.id) == nil)
        #expect(!index.contains(noteID: note.id))
        #expect(try index.search("budget").isEmpty)
    }

    @Test func linesAndNotesOutsideTheHourAndRollupsSurvive() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let transcripts = TranscriptStore(paths: paths, calendar: Self.calendar)
        let notes = NoteStore(paths: paths, calendar: Self.calendar)
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        let now = forgetAt(14, 5)
        let justBefore = TranscriptLine(time: forgetAt(13, 5).addingTimeInterval(-1), label: .me, text: "Before.")
        let atStart = TranscriptLine(time: forgetAt(13, 5), label: .me, text: "Start.")
        let atNow = TranscriptLine(time: now, label: .others, text: "Now.")
        let after = TranscriptLine(time: forgetAt(14, 6), label: .me, text: "After.")
        for line in [justBefore, atStart, atNow, after] { try transcripts.append(line) }
        func forgetNote(_ kind: NoteKind, _ start: Date, _ end: Date) throws -> String {
            let period = DateInterval(start: start, end: end)
            let note = Note(kind: kind, id: notes.id(kind, period: period), period: period, body: "lunch")
            try notes.write(note)
            try index.add(noteID: note.id, text: note.body)
            return note.id
        }
        let endsBefore = try forgetNote(.hourly, forgetAt(12), forgetAt(13))
        let overlapping = try forgetNote(.hourly, forgetAt(13), forgetAt(14))
        let demo = try forgetNote(.hourly, forgetAt(14), forgetAt(14, 5))
        let daily = try forgetNote(.daily, forgetAt(0), forgetAt(23, 59))
        let forget = ForgetLastHour(transcripts: transcripts, notes: notes, index: index, calendar: Self.calendar)

        let report = try forget.perform(now: now)

        #expect(report.linesDeleted == 2)
        #expect(report.noteIDs == [overlapping, demo])
        let day = DateInterval(start: forgetAt(0), end: forgetAt(23, 59))
        #expect(try transcripts.lines(in: day) == [justBefore, after])
        #expect(notes.allIDs(kind: .hourly) == [endsBefore])
        #expect(notes.note(id: daily) != nil)
        #expect(Set(try index.search("lunch", k: 10).map(\.noteID)) == [endsBefore, daily])
    }

    @Test func describeNamesTheTimesAndLiveCounts() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let transcripts = TranscriptStore(paths: paths, calendar: Self.calendar)
        let notes = NoteStore(paths: paths, calendar: Self.calendar)
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        let forget = ForgetLastHour(transcripts: transcripts, notes: notes, index: index, calendar: Self.calendar)
        let now = forgetAt(14, 5)
        #expect(try forget.describe(now: now) == "Delete the last hour, 13:05 to 14:05: 0 transcript lines and 0 notes?")

        try transcripts.append(TranscriptLine(time: forgetAt(13, 30), label: .me, text: "One."))
        let hour = DateInterval(start: forgetAt(13), end: forgetAt(14))
        try notes.write(Note(kind: .hourly, id: notes.id(.hourly, period: hour), period: hour, body: "x"))
        #expect(try forget.describe(now: now) == "Delete the last hour, 13:05 to 14:05: 1 transcript line and 1 note?")

        try transcripts.append(TranscriptLine(time: forgetAt(13, 40), label: .others, text: "Two."))
        #expect(try forget.describe(now: now) == "Delete the last hour, 13:05 to 14:05: 2 transcript lines and 1 note?")
    }
}
