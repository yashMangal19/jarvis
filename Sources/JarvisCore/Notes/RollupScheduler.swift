import Foundation

/// Rolls hourly notes up into one daily note per completed local day, and daily notes up into one
/// weekly note per completed ISO week (Monday–Sunday).
public final class RollupScheduler {
    private let notes: NoteStore
    private let writer: () -> (any NoteWriter)?
    private let prompts: PromptStore
    private let calendar: Calendar
    private let weekCalendar: Calendar

    /// `writer` returning `nil` means no note writer is installed: roll-ups are skipped quietly.
    public init(notes: NoteStore,
                writer: @escaping () -> (any NoteWriter)?,
                prompts: PromptStore,
                calendar: Calendar = .current) {
        self.notes = notes
        self.writer = writer
        self.prompts = prompts
        self.calendar = calendar
        var week = Calendar(identifier: .iso8601)
        week.timeZone = calendar.timeZone
        weekCalendar = week
    }

    /// Writes every missing daily note for a completed day that has hourly notes (Demo-slot notes
    /// count: they are the same folder and the same speech), then every missing weekly note for a
    /// completed week that has daily notes. An existing roll-up is never rewritten.
    public func runIfDue(now: Date) async throws {
        guard let writer = writer() else { return }
        try await rollUp(.hourly, into: .daily, periodOf: { calendar.dateInterval(of: .day, for: $0) },
                         prompt: .daily, writer: writer, now: now)
        try await rollUp(.daily, into: .weekly, periodOf: { weekCalendar.dateInterval(of: .weekOfYear, for: $0) },
                         prompt: .weekly, writer: writer, now: now)
    }

    private func rollUp(_ source: NoteKind, into target: NoteKind,
                        periodOf: (Date) -> DateInterval?, prompt: PromptKind,
                        writer: any NoteWriter, now: Date) async throws {
        let all = notes.notes(kind: source, intersecting: DateInterval(start: .distantPast, end: .distantFuture))
        let existing = Set(notes.allIDs(kind: target))
        let groups = Dictionary(grouping: all) { periodOf($0.period.start) }
        for (period, members) in groups.sorted(by: { ($0.key?.start ?? .distantPast) < ($1.key?.start ?? .distantPast) }) {
            guard let period, period.end <= now else { continue }
            let id = notes.id(target, period: period)
            guard !existing.contains(id) else { continue }
            let joined = members.map { "## \($0.id)\n\($0.body)" }.joined(separator: "\n\n")
            let body = try await writer.note(from: joined, prompt: prompts.prompt(prompt))
            try notes.write(Note(kind: target, id: id, period: period, body: body))
        }
    }
}
