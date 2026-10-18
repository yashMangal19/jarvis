import Foundation
import Testing
import JarvisCore

@Suite struct NoteStoreTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-\(UUID().uuidString)")
    var paths: JarvisPaths { JarvisPaths(root: root) }
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func hourly(_ day: Int, _ hour: Int, _ store: NoteStore) -> Note {
        let period = DateInterval(start: at(day, hour), end: at(day, hour + 1))
        return Note(kind: .hourly, id: store.id(.hourly, period: period), period: period, body: "Body \(hour)")
    }

    @Test func notesIntersectingAPeriodAreReadBackWithTheirPeriodAndBody() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(paths: paths, calendar: Self.calendar)
        let nine = hourly(17, 9, store), ten = hourly(17, 10, store), eleven = hourly(17, 11, store)
        for note in [eleven, nine, ten] { try store.write(note) }

        let found = store.notes(kind: .hourly, intersecting: DateInterval(start: at(17, 9, 30), end: at(17, 10, 30)))

        #expect(found == [nine, ten])
    }

    // T-26 F-1: the Ask panel opens a note through the store, so it follows the paths Jarvis was built with.
    @Test func fileFindsTheNoteOfAnyKindByIDAndNothingOnceItIsGone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(paths: paths, calendar: Self.calendar)
        let ten = hourly(17, 10, store)
        let day = Note(kind: .daily, id: "2026-10-17", period: DateInterval(start: at(17, 0), end: at(18, 0)), body: "Day")
        let tenFile = try store.write(ten)
        let dayFile = try store.write(day)

        #expect(store.file(id: ten.id) == tenFile)
        #expect(store.file(id: day.id) == dayFile)
        #expect(store.file(id: "2026-10-17-23") == nil)

        try store.delete(id: ten.id)
        #expect(store.file(id: ten.id) == nil)
    }

    @Test func onWriteSeesEachWrittenNoteAndDeleteRemovesIt() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(paths: paths, calendar: Self.calendar)
        var seen: [(String, URL)] = []
        store.onWrite = { note, url in seen.append((note.id, url)) }
        let ten = hourly(17, 10, store)

        let url = try store.write(ten)
        #expect(seen.map(\.0) == ["2026-10-17-10"])
        #expect(seen.map(\.1) == [url])

        try store.delete(id: ten.id)
        #expect(store.note(id: ten.id) == nil)
        #expect(store.allIDs(kind: .hourly).isEmpty)
    }

    @Test func dailyAndWeeklyIdsEncodeTheirPeriod() {
        let store = NoteStore(paths: paths, calendar: Self.calendar)
        let day = DateInterval(start: at(17, 0), end: at(18, 0))
        // 2026-10-17 is a Saturday in ISO week 42; 2027-01-01 (a Friday) is in 2026's week 53.
        let newYearWeek = DateInterval(start: Self.calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!,
                                       duration: 7 * 86_400)

        #expect(store.id(.daily, period: day) == "2026-10-17")
        #expect(store.id(.weekly, period: day) == "2026-W42")
        #expect(store.id(.weekly, period: newYearWeek) == "2026-W53")
    }
}
