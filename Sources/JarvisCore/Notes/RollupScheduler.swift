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

    /// A period is due this long after it ends, so the hourly note for its last hour (written at
    /// the end of that hour) is in before the roll-up is made.
    static let grace: TimeInterval = 5 * 60

    /// Writes every missing daily note for a completed day that has hourly notes (Demo-slot notes
    /// count: they are the same folder and the same speech), then every missing weekly note for a
    /// completed week that has daily notes. An existing roll-up is never rewritten. A period whose
    /// roll-up fails is skipped, left missing for the next run, and returned; the others still run.
    @discardableResult
    public func runIfDue(now: Date) async -> [(id: String, error: any Error)] {
        guard let writer = writer() else { return [] }
        return await rollUp(.hourly, into: .daily, periodOf: { calendar.dateInterval(of: .day, for: $0) },
                            prompt: .daily, writer: writer, now: now)
            + rollUp(.daily, into: .weekly, periodOf: { weekCalendar.dateInterval(of: .weekOfYear, for: $0) },
                     prompt: .weekly, writer: writer, now: now)
    }

    /// Groups source ids by target period from the id alone (every id starts `YYYY-MM-DD`, the local
    /// day of its period start), so only the bodies of periods being rolled up are read.
    private func rollUp(_ source: NoteKind, into target: NoteKind,
                        periodOf: (Date) -> DateInterval?, prompt: PromptKind,
                        writer: any NoteWriter, now: Date) async -> [(id: String, error: any Error)] {
        let existing = Set(notes.allIDs(kind: target))
        let groups = Dictionary(grouping: notes.allIDs(kind: source)) { day(ofID: $0).flatMap(periodOf) }
        var failures: [(id: String, error: any Error)] = []
        for (period, ids) in groups.sorted(by: { ($0.key?.start ?? .distantPast) < ($1.key?.start ?? .distantPast) }) {
            guard let period, now >= period.end.addingTimeInterval(Self.grace) else { continue }
            let id = notes.id(target, period: period)
            guard !existing.contains(id) else { continue }
            let members = ids.compactMap { notes.note(id: $0) }.sorted { $0.period.start < $1.period.start }
            guard !members.isEmpty else { continue }
            let joined = members.map { "## \($0.id)\n\($0.body)" }.joined(separator: "\n\n")
            do {
                let body = try await writer.note(from: joined, prompt: prompts.prompt(prompt))
                try notes.write(Note(kind: target, id: id, period: period, body: body))
            } catch {
                failures.append((id, error))
            }
        }
        return failures
    }

    private func day(ofID id: String) -> Date? {
        let parts = id.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
