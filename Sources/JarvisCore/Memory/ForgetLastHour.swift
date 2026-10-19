import Foundation

/// What `ForgetLastHour.perform` removed.
public struct ForgetReport {
    public let linesDeleted: Int
    /// Hourly notes removed from the store and the index, oldest first.
    public let noteIDs: [String]
}

/// Removes the last hour from memory everywhere it lives: transcript lines, voice-command records, the hourly notes
/// (Demo notes included) whose period overlaps it, and their search vectors. Daily and weekly
/// roll-ups are left alone.
public final class ForgetLastHour {
    private let transcripts: TranscriptStore
    private let notes: NoteStore
    private let index: NoteIndex
    private let forgotten: ForgottenWindows?
    private let commandLog: CommandLog?
    private let calendar: Calendar

    /// `index` must be the app's one `NoteIndex` instance: it owns `vectors.json`. `forgotten` must
    /// be the instance the capture pipeline and note scheduler share, so speech in flight is dropped.
    public init(transcripts: TranscriptStore, notes: NoteStore, index: NoteIndex,
                forgotten: ForgottenWindows? = nil, commandLog: CommandLog? = nil, calendar: Calendar = .current) {
        self.transcripts = transcripts
        self.commandLog = commandLog
        self.notes = notes
        self.index = index
        self.forgotten = forgotten
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
        let noteCount = noteIDs(intersecting: window).count
        return "Delete the last hour, \(clock(window.start)) to \(clock(window.end)): "
            + "\(count(lines, "transcript line")) and \(count(noteCount, "note"))?"
    }

    /// The window is recorded as forgotten before anything is deleted, so a line or note still in
    /// flight is dropped rather than written into it. Each note leaves the index before its file, so
    /// a failure part-way leaves the file: a rerun finds it and removes both, saving the index even
    /// when the vector already left memory.
    public func perform(now: Date) throws -> ForgetReport {
        let lines = lineWindow(now: now)
        try forgotten?.record(lines, now: now)
        let linesDeleted = try transcripts.lines(in: lines).count
        try transcripts.deleteLines(in: lines)
        try commandLog?.deleteRecords(in: lines)
        let ids = noteIDs(intersecting: window(now: now))
        for id in ids {
            try index.remove(noteID: id)
            try notes.delete(id: id)
        }
        return ForgetReport(linesDeleted: linesDeleted, noteIDs: ids)
    }

    /// Hourly notes overlapping `window`, oldest first, including files whose front matter does not
    /// parse: those are matched by the period their name encodes, a Demo name (`HHmm`) as one slot.
    private func noteIDs(intersecting window: DateInterval) -> [String] {
        notes.allIDs(kind: .hourly).filter { id in
            guard let period = notes.note(id: id)?.period ?? period(ofHourlyID: id) else { return false }
            return period.start < window.end && window.start < period.end
        }
    }

    /// `YYYY-MM-DD-HH` is that hour, `YYYY-MM-DD-HHmm` the 2-minute Demo slot starting then.
    private func period(ofHourlyID id: String) -> DateInterval? {
        let parts = id.split(separator: "-").map { Int($0) }
        guard parts.count == 4, let year = parts[0], let month = parts[1], let day = parts[2], let time = parts[3]
        else { return nil }
        let isHour = id.count == "YYYY-MM-DD-HH".count
        guard isHour || id.count == "YYYY-MM-DD-HHmm".count,
              let start = calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                             hour: isHour ? time : time / 100,
                                                             minute: isHour ? 0 : time % 100))
        else { return nil }
        return DateInterval(start: start, duration: isHour ? 3600 : 120)
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
