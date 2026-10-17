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

    // F-3: a save that fails part-way is written by the rerun, so a relaunch never finds the vector.
    @Test func aRerunAfterAFailedIndexSavePersistsTheRemoval() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let transcripts = TranscriptStore(paths: paths, calendar: Self.calendar)
        let notes = NoteStore(paths: paths, calendar: Self.calendar)
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        let hour = DateInterval(start: forgetAt(13), end: forgetAt(14))
        let note = Note(kind: .hourly, id: notes.id(.hourly, period: hour), period: hour, body: "Budget talk")
        try notes.write(note)
        try index.add(noteID: note.id, text: note.body)
        let forget = ForgetLastHour(transcripts: transcripts, notes: notes, index: index, calendar: Self.calendar)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.index.path)
        #expect(throws: (any Error).self) { try forget.perform(now: forgetAt(14, 5)) }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.index.path)

        let report = try forget.perform(now: forgetAt(14, 5))

        #expect(report.noteIDs == [note.id])
        #expect(notes.note(id: note.id) == nil)
        let relaunched = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        #expect(!relaunched.contains(noteID: note.id))
    }

    // F-4: an hourly file whose front matter does not parse is matched by the period in its name.
    @Test func anUnreadableHourlyFileOfTheHourGoesWithItsVector() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let transcripts = TranscriptStore(paths: paths, calendar: Self.calendar)
        let notes = NoteStore(paths: paths, calendar: Self.calendar)
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        try FileManager.default.createDirectory(at: paths.notesHourly, withIntermediateDirectories: true)
        func broken(_ id: String) throws -> String {
            try "no front matter, budget".write(to: paths.notesHourly.appending(path: "\(id).md"), atomically: true, encoding: .utf8)
            try index.add(noteID: id, text: "budget")
            return id
        }
        let hour = try broken("2026-10-17-13")
        let demo = try broken("2026-10-17-1400")
        let before = try broken("2026-10-17-12")
        let demoBefore = try broken("2026-10-17-1302")
        let forget = ForgetLastHour(transcripts: transcripts, notes: notes, index: index, calendar: Self.calendar)
        #expect(try forget.describe(now: forgetAt(14, 5)).hasSuffix("0 transcript lines and 2 notes?"))

        let report = try forget.perform(now: forgetAt(14, 5))

        #expect(report.noteIDs == [hour, demo])
        #expect(notes.allIDs(kind: .hourly) == [before, demoBefore])
        #expect(Set(try index.search("budget", k: 10).map(\.noteID)) == [before, demoBefore])
    }

    // F-1/F-2: the window is recorded before anything is deleted, survives a relaunch, and is pruned
    // once its transcripts would have been purged anyway.
    @Test func performRecordsTheWindowWhichPersistsAndIsPrunedAfterRetention() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let transcripts = TranscriptStore(paths: paths, calendar: Self.calendar)
        let notes = NoteStore(paths: paths, calendar: Self.calendar)
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        let forgotten = ForgottenWindows(paths: paths)
        let forget = ForgetLastHour(transcripts: transcripts, notes: notes, index: index,
                                    forgotten: forgotten, calendar: Self.calendar)
        let now = forgetAt(14, 5)

        _ = try forget.perform(now: now)

        #expect(forgotten.contains(forgetAt(13, 5)))
        #expect(forgotten.contains(now))
        #expect(!forgotten.contains(forgetAt(13, 5).addingTimeInterval(-1)))
        #expect(!forgotten.contains(forgetAt(14, 6)))
        #expect(ForgottenWindows(paths: paths).contains(forgetAt(13, 30)))

        try forgotten.record(DateInterval(start: now, duration: 1), now: now.addingTimeInterval(9 * 86_400))
        #expect(!ForgottenWindows(paths: paths).contains(forgetAt(13, 30)))
    }
}
