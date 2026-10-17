import Foundation
import Testing
import JarvisCore

@Suite struct TranscriptStoreTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-\(UUID().uuidString)")
    var paths: JarvisPaths { JarvisPaths(root: root) }

    /// Fixed zone so day files are deterministic wherever the tests run.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    /// A local time in the test zone. Whole seconds: the file stores ISO-8601 to the second.
    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                hour: hour, minute: minute))!
    }

    func makeStore() -> TranscriptStore {
        TranscriptStore(paths: paths, calendar: Self.calendar)
    }

    @Test func appendedLineIsReadBackWithItsLabel() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore()
        let line = TranscriptLine(time: at(2026, 10, 17, 10, 15), label: .others, text: "Ship it Friday.")

        try store.append(line)

        let window = DateInterval(start: at(2026, 10, 17, 10), end: at(2026, 10, 17, 11))
        #expect(try store.lines(in: window) == [line])
    }

    @Test func windowAcrossMidnightReadsBothDayFilesInOrder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore()
        let beforeMidnight = TranscriptLine(time: at(2026, 10, 16, 23, 40), label: .me, text: "Late.")
        let afterMidnight = TranscriptLine(time: at(2026, 10, 17, 0, 20), label: .others, text: "Early.")
        let outside = TranscriptLine(time: at(2026, 10, 17, 2, 0), label: .me, text: "Later.")
        try store.append(afterMidnight)
        try store.append(outside)
        try store.append(beforeMidnight)

        let window = DateInterval(start: at(2026, 10, 16, 23, 30), end: at(2026, 10, 17, 0, 30))
        #expect(try store.lines(in: window) == [beforeMidnight, afterMidnight])
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.transcripts.path).sorted()
        #expect(names == ["2026-10-16.jsonl", "2026-10-17.jsonl"])
    }

    @Test func deleteLinesKeepsNeighboursAndRemovesEmptiedFile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore()
        let onlyLineOfDay = TranscriptLine(time: at(2026, 10, 16, 23, 50), label: .me, text: "Forget me.")
        let inWindow = TranscriptLine(time: at(2026, 10, 17, 0, 10), label: .others, text: "Forget me too.")
        let neighbour = TranscriptLine(time: at(2026, 10, 17, 1, 0), label: .me, text: "Keep me.")
        for line in [onlyLineOfDay, inWindow, neighbour] { try store.append(line) }

        try store.deleteLines(in: DateInterval(start: at(2026, 10, 16, 23, 30), end: at(2026, 10, 17, 0, 30)))

        let wholeRange = DateInterval(start: at(2026, 10, 16, 0), end: at(2026, 10, 18, 0))
        #expect(try store.lines(in: wholeRange) == [neighbour])
        #expect(!FileManager.default.fileExists(atPath: paths.transcripts.appending(path: "2026-10-16.jsonl").path))
    }

    @Test func purgeRemovesOnlyDaysOlderThanSevenAndLeavesNotesAlone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try paths.ensureLayout()
        let store = makeStore()
        for day in [9, 10, 11] {  // 8, 7 and 6 days before the 17th
            try store.append(TranscriptLine(time: at(2026, 10, day, 12), label: .me, text: "Day \(day)."))
        }
        let oldNote = paths.notesHourly.appending(path: "2026-10-01-09.md")
        try Data("# old note".utf8).write(to: oldNote)

        let removed = try store.purge(now: at(2026, 10, 17, 9))

        #expect(removed.map(\.lastPathComponent) == ["2026-10-09.jsonl"])
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.transcripts.path).sorted()
        #expect(names == ["2026-10-10.jsonl", "2026-10-11.jsonl"])
        #expect(FileManager.default.fileExists(atPath: oldNote.path))
    }

    @Test func dayFileIsOneJSONObjectPerLineWithISOTime() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore()
        try store.append(TranscriptLine(time: at(2026, 10, 17, 10, 15), label: .me, text: "Line one\nstill one."))
        try store.append(TranscriptLine(time: at(2026, 10, 17, 10, 16), label: .others, text: "Two."))

        let text = try String(contentsOf: paths.transcripts.appending(path: "2026-10-17.jsonl"), encoding: .utf8)
        let rows = text.split(separator: "\n")
        #expect(rows.count == 2 && text.hasSuffix("\n"))
        let first = try JSONSerialization.jsonObject(with: Data(rows[0].utf8)) as? [String: String]
        // 10:15 in Kolkata (+05:30) is 04:45 UTC.
        #expect(first == ["time": "2026-10-17T04:45:00Z", "label": "Me", "text": "Line one\nstill one."])
    }

    @Test func tornLastLineIsSkippedOnReadAndDroppedByDelete() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore()
        let kept = TranscriptLine(time: at(2026, 10, 17, 10, 5), label: .me, text: "Keep me.")
        let forgotten = TranscriptLine(time: at(2026, 10, 17, 10, 40), label: .others, text: "Forget me.")
        try store.append(kept)
        try store.append(forgotten)
        let file = paths.transcripts.appending(path: "2026-10-17.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"time":"2026-10-17T05:20:00Z","lab"#.utf8))  // crash mid-write
        try handle.close()

        let hour = DateInterval(start: at(2026, 10, 17, 10), end: at(2026, 10, 17, 11))
        #expect(try store.lines(in: hour) == [kept, forgotten])

        try store.deleteLines(in: DateInterval(start: at(2026, 10, 17, 10, 30), end: at(2026, 10, 17, 11)))
        #expect(try store.lines(in: hour) == [kept])
        let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(rows.count == 1)
    }

    @Test func lineAppendedAfterTornLineIsNotGluedOntoIt() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore()
        try paths.ensureLayout()
        let file = paths.transcripts.appending(path: "2026-10-17.jsonl")
        try Data(#"{"time":"2026-10-17T04:40:00Z","lab"#.utf8).write(to: file)  // crash mid-write
        let good = TranscriptLine(time: at(2026, 10, 17, 10, 15), label: .me, text: "After the crash.")

        try store.append(good)

        #expect(try store.lines(in: DateInterval(start: at(2026, 10, 17, 10), end: at(2026, 10, 17, 11))) == [good])
    }

    @Test func lineWrittenInAnotherTimeZoneIsFoundAndDeleted() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 00:20 on the 17th in Kolkata is 18:50 on the 16th in UTC: written to the 17th's file.
        let line = TranscriptLine(time: at(2026, 10, 17, 0, 20), label: .me, text: "Travelled.")
        try makeStore().append(line)

        let utcStore = TranscriptStore(paths: paths, calendar: utc)
        let utcHour = DateInterval(start: utc.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 18))!,
                                   duration: 3600)
        #expect(try utcStore.lines(in: utcHour) == [line])
        try utcStore.deleteLines(in: utcHour)
        #expect(try makeStore().lines(in: DateInterval(start: at(2026, 10, 16, 0), end: at(2026, 10, 18, 0))).isEmpty)
    }

    @Test func fractionalSecondLineRoundTripsEqual() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore()
        let line = TranscriptLine(time: at(2026, 10, 17, 10, 15).addingTimeInterval(0.75), label: .me, text: "Mid-second.")

        try store.append(line)

        #expect(try store.lines(in: DateInterval(start: at(2026, 10, 17, 10), end: at(2026, 10, 17, 11))) == [line])
    }

    // F-5: an append racing a delete-rewrite of the same day file is never lost.
    @Test func appendsDuringDeleteLinesAreNeverLost() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let forgotten = DateInterval(start: at(2026, 10, 17, 13), end: at(2026, 10, 17, 14))
        let count = 300
        let appender = Task.detached { [paths] in
            let store = TranscriptStore(paths: paths, calendar: Self.calendar)
            for i in 0..<count {
                try store.append(TranscriptLine(time: forgotten.start.addingTimeInterval(Double(i)), label: .me, text: "gone"))
                try store.append(TranscriptLine(time: forgotten.end.addingTimeInterval(Double(i)), label: .me, text: "kept \(i)"))
            }
        }
        let deleter = Task.detached { [paths] in
            let store = TranscriptStore(paths: paths, calendar: Self.calendar)
            for _ in 0..<count { try store.deleteLines(in: forgotten) }
        }
        try await appender.value
        try await deleter.value
        let store = makeStore()
        try store.deleteLines(in: forgotten)

        #expect(try store.lines(in: DateInterval(start: forgotten.end, duration: 3600)).count == count)
    }
}
