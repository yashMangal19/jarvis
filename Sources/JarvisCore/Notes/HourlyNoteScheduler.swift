import Foundation

/// Writes one Markdown note per completed hour that had speech.
public final class HourlyNoteScheduler {
    private let transcripts: TranscriptStore
    private let session: ListeningSession
    private let writer: () -> (any NoteWriter)?
    private let prompts: PromptStore
    private let notes: NoteStore
    private let calendar: Calendar

    /// `writer` returning `nil` means no note writer is installed: notes are skipped quietly and
    /// transcripts keep accumulating.
    public init(transcripts: TranscriptStore,
                session: ListeningSession,
                writer: @escaping () -> (any NoteWriter)?,
                prompts: PromptStore,
                notes: NoteStore,
                calendar: Calendar = .current) {
        self.transcripts = transcripts
        self.session = session
        self.writer = writer
        self.prompts = prompts
        self.notes = notes
        self.calendar = calendar
    }

    /// Writes the note for the most recently completed hour — in Demo mode, the most recently
    /// completed 2-minute slot of the clock (:00–:02, :02–:04, …) — once: an existing note for that
    /// window is never rewritten, so every later tick in the same window is a no-op.
    public func tick(now: Date) async throws {
        guard let window = lastCompletedWindow(before: now),
              notes.note(id: notes.id(.hourly, period: window)) == nil else { return }
        try await writeNote(for: window)
    }

    /// The note for `window` from its transcript lines, with the window's gap markers appended
    /// under `## Gaps` when there are any; `nil` (and no file) when the window had
    /// no speech or no note writer is installed. Public so importers can note a past hour.
    @discardableResult
    public func writeNote(for window: DateInterval) async throws -> URL? {
        let lines = try transcripts.lines(in: window)
        guard !lines.isEmpty, let writer = writer() else { return nil }
        var body = try await writer.note(from: format(lines), prompt: prompts.prompt(.hourly))
        let gaps = session.gapMarkers(in: window)
        if !gaps.isEmpty {
            body += "\n\n## Gaps\n" + gaps.map { "- \($0)" }.joined(separator: "\n")
        }
        return try notes.write(Note(kind: .hourly, id: notes.id(.hourly, period: window),
                                    period: window, body: body))
    }

    private func lastCompletedWindow(before now: Date) -> DateInterval? {
        guard let hour = calendar.dateInterval(of: .hour, for: now) else { return nil }
        guard session.modes.demoMode else {
            return calendar.date(byAdding: .hour, value: -1, to: hour.start)
                .map { DateInterval(start: $0, end: hour.start) }
        }
        let slotEnd = hour.start.addingTimeInterval(Double(Int(now.timeIntervalSince(hour.start)) / 120 * 120))
        return DateInterval(start: slotEnd.addingTimeInterval(-120), end: slotEnd)
    }

    /// `HH:MM Me: text`, one per line, local time of `calendar`.
    private func format(_ lines: [TranscriptLine]) -> String {
        lines.map { line in
            let c = calendar.dateComponents([.hour, .minute], from: line.time)
            return String(format: "%02d:%02d ", c.hour!, c.minute!) + "\(line.label.rawValue): \(line.text)"
        }.joined(separator: "\n")
    }
}
