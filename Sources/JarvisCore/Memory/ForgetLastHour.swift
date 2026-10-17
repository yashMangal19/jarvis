import Foundation

/// What `ForgetLastHour.perform` removed.
public struct ForgetReport {
    public let linesDeleted: Int
    /// Hourly notes removed from the store and the index, oldest first.
    public let noteIDs: [String]
}

/// Removes the last hour from memory everywhere it lives: transcript lines, the hourly notes
/// (Demo notes included) whose period overlaps it, and their search vectors. Daily and weekly
/// roll-ups are left alone.
public final class ForgetLastHour {
    private let transcripts: TranscriptStore
    private let notes: NoteStore
    private let index: NoteIndex
    private let calendar: Calendar

    /// `index` must be the app's one `NoteIndex` instance: it owns `vectors.json`.
    public init(transcripts: TranscriptStore, notes: NoteStore, index: NoteIndex, calendar: Calendar = .current) {
        self.transcripts = transcripts
        self.notes = notes
        self.index = index
        self.calendar = calendar
    }

    /// `[now - 1h, now]`.
    public func window(now: Date) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-3600), end: now)
    }

    /// The question asked before `perform`, with live counts, e.g.
    /// "Delete the last hour, 13:05 to 14:05: 12 transcript lines and 1 note?"
    public func describe(now: Date) throws -> String {
        let window = window(now: now)
        let lines = try transcripts.lines(in: lineWindow(now: now)).count
        let noteCount = notes.notes(kind: .hourly, intersecting: window).count
        return "Delete the last hour, \(clock(window.start)) to \(clock(window.end)): "
            + "\(count(lines, "transcript line")) and \(count(noteCount, "note"))?"
    }

    /// Each note leaves the index before its file, so a failure part-way never leaves a vector
    /// whose note is gone unnoticed: a rerun finds the file and removes both.
    public func perform(now: Date) throws -> ForgetReport {
        let lines = lineWindow(now: now)
        let linesDeleted = try transcripts.lines(in: lines).count
        try transcripts.deleteLines(in: lines)
        let ids = notes.notes(kind: .hourly, intersecting: window(now: now)).map(\.id)
        for id in ids {
            try index.remove(noteID: id)
            try notes.delete(id: id)
        }
        return ForgetReport(linesDeleted: linesDeleted, noteIDs: ids)
    }

    /// Line times are stored truncated to the second and the store's window is end-exclusive, so
    /// both ends snap to whole seconds and the end moves one second on: every line spoken at or
    /// before `now` goes, at the cost of at most a second of over-deletion at either end.
    private func lineWindow(now: Date) -> DateInterval {
        let window = window(now: now)
        let start = window.start.timeIntervalSince1970.rounded(.down)
        let end = window.end.timeIntervalSince1970.rounded(.down) + 1
        return DateInterval(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
    }

    private func clock(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    private func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
