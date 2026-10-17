import Foundation

/// Writes one Markdown note per completed hour that had speech.
public final class HourlyNoteScheduler {
    private let transcripts: TranscriptStore
    private let session: ListeningSession
    private let writer: () -> (any NoteWriter)?
    private let prompts: PromptStore
    private let notes: NoteStore
    private let forgotten: ForgottenWindows?
    private let calendar: Calendar
    /// Ids whose note is being written now, so an overlapping tick for the same window is a no-op.
    private var inFlight: Set<String> = []
    /// Ids a `renote` asked for while they were in flight: written once more when that write ends.
    private var writeAgain: Set<String> = []
    private let lock = NSLock()

    /// `writer` returning `nil` means no note writer is installed: notes are skipped quietly and
    /// transcripts keep accumulating.
    public init(transcripts: TranscriptStore,
                session: ListeningSession,
                writer: @escaping () -> (any NoteWriter)?,
                prompts: PromptStore,
                notes: NoteStore,
                forgotten: ForgottenWindows? = nil,
                calendar: Calendar = .current) {
        self.transcripts = transcripts
        self.session = session
        self.writer = writer
        self.prompts = prompts
        self.notes = notes
        self.forgotten = forgotten
        self.calendar = calendar
    }

    /// Writes the note for the most recently completed hour — in Demo mode, the most recently
    /// completed 2-minute slot of the clock (:00–:02, :02–:04, …) — once: an existing note for that
    /// window is never rewritten, even when it no longer parses, and a tick that overlaps one
    /// still writing that window is a no-op. Every prompt file is seeded first, before any of that.
    public func tick(now: Date) async throws {
        try prompts.seedDefaults()
        guard let window = lastCompletedWindow(before: now) else { return }
        try await write(window, onlyIfMissing: true)
    }

    /// Writes again the note of every finished window `period` touches (an import stored lines there),
    /// in the windows `tick` uses: hours, or 2-minute slots in Demo mode. The window still in progress
    /// at `now` is left to `tick`, so its note is written once, after it ends, from every line (DEC-26).
    /// A window being written right now is written once more when that write ends, never raced.
    public func renote(touching period: DateInterval, now: Date) async throws {
        var window = self.window(containing: period.start)
        while let current = window, current.start < period.end, current.end <= now {
            try await write(current, onlyIfMissing: false)
            window = self.window(containing: current.end)
        }
    }

    /// Claims `window` so no two writes of it overlap. A tick (`onlyIfMissing`) skips a window that
    /// has a note or is in flight; a re-note of an in-flight window asks its writer to write it again.
    private func write(_ window: DateInterval, onlyIfMissing: Bool) async throws {
        let id = notes.id(.hourly, period: window)
        let claimed = lock.withLock {
            if onlyIfMissing, notes.allIDs(kind: .hourly).contains(id) { return false }
            if inFlight.insert(id).inserted { return true }
            if !onlyIfMissing { writeAgain.insert(id) }
            return false
        }
        guard claimed else { return }
        defer { lock.withLock { inFlight.remove(id); writeAgain.remove(id) } }
        repeat { try await writeNote(for: window) } while lock.withLock { writeAgain.remove(id) != nil }
    }

    /// The note for `window` from its transcript lines, with the window's gap markers appended
    /// under `## Gaps` when there are any; `nil` (and no file) when the window had
    /// no speech or no note writer is installed. Importers go through `renote`, which claims the window.
    /// Forgotten lines are never sent to the writer, and a note is not written (`nil`) if any line
    /// it was written from was forgotten while the writer ran; a later tick writes it from what is left.
    @discardableResult
    public func writeNote(for window: DateInterval) async throws -> URL? {
        let lines = try transcripts.lines(in: window).filter { !(forgotten?.contains($0.time) ?? false) }
        guard !lines.isEmpty, let writer = writer() else { return nil }
        var body = try await writer.note(from: format(lines), prompt: prompts.prompt(.hourly))
        // Not `session.gapMarkers`: that formats in the device zone, these follow `calendar`.
        let gaps = session.gaps(in: window)
        if !gaps.isEmpty {
            body += "\n\n## Gaps\n" + gaps.map {
                "- \(hhmm($0.start))–\(hhmm($0.end)): not listening (\($0.reason))"
            }.joined(separator: "\n")
        }
        let note = Note(kind: .hourly, id: notes.id(.hourly, period: window), period: window, body: body)
        guard let forgotten else { return try notes.write(note) }
        return try forgotten.unlessForgotten(lines.map(\.time)) { try notes.write(note) }
    }

    private func lastCompletedWindow(before now: Date) -> DateInterval? {
        window(containing: now).map { current in
            DateInterval(start: current.start.addingTimeInterval(-current.duration), end: current.start)
        }
    }

    /// The hour holding `date`, or in Demo mode its 2-minute slot of the clock (:00–:02, :02–:04, …).
    private func window(containing date: Date) -> DateInterval? {
        guard let hour = calendar.dateInterval(of: .hour, for: date) else { return nil }
        guard session.modes.demoMode else { return hour }
        let slotStart = hour.start.addingTimeInterval(Double(Int(date.timeIntervalSince(hour.start)) / 120 * 120))
        return DateInterval(start: slotStart, duration: 120)
    }

    /// `HH:MM Me: text`, one per line, local time of `calendar`.
    private func format(_ lines: [TranscriptLine]) -> String {
        lines.map { "\(hhmm($0.time)) \($0.label.rawValue): \($0.text)" }.joined(separator: "\n")
    }

    /// `HH:MM`, local time of `calendar`.
    private func hhmm(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }
}
