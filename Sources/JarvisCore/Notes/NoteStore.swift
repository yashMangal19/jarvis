import Foundation

public enum NoteKind: CaseIterable {
    case hourly, daily, weekly
}

public struct Note: Equatable {
    public let kind: NoteKind
    public let id: String
    public let period: DateInterval
    public let body: String

    public init(kind: NoteKind, id: String, period: DateInterval, body: String) {
        self.kind = kind
        self.id = id
        self.period = period
        self.body = body
    }
}

/// `notes/{hourly,daily,weekly}/<id>.md`. The id encodes the period; a one-line front matter
/// `period: <iso start>/<iso end>` makes the exact period recoverable from the file alone.
public final class NoteStore {
    private let paths: JarvisPaths
    private let calendar: Calendar
    private let iso: ISO8601DateFormatter
    /// Called after every successful `write`, with the note and its file.
    public var onWrite: ((Note, URL) -> Void)?

    public init(paths: JarvisPaths, calendar: Calendar = .current) {
        self.paths = paths
        self.calendar = calendar
        iso = ISO8601DateFormatter()
        iso.timeZone = calendar.timeZone
    }

    /// `YYYY-MM-DD-HH` for an hour, `YYYY-MM-DD-HHmm` for a shorter (Demo) period,
    /// `YYYY-MM-DD` for a day, `YYYY-Www` (ISO week) for a week. Local time of `calendar`.
    public func id(_ kind: NoteKind, period: DateInterval) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: period.start)
        let day = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        switch kind {
        case .hourly where period.duration < 3600:
            return day + String(format: "-%02d%02d", c.hour!, c.minute!)
        case .hourly:
            return day + String(format: "-%02d", c.hour!)
        case .daily:
            return day
        case .weekly:
            var isoCalendar = Calendar(identifier: .iso8601)
            isoCalendar.timeZone = calendar.timeZone
            let w = isoCalendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: period.start)
            return String(format: "%04d-W%02d", w.yearForWeekOfYear!, w.weekOfYear!)
        }
    }

    /// Writes (or replaces) the note's file.
    @discardableResult
    public func write(_ note: Note) throws -> URL {
        let folder = folder(note.kind)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(note.id).md")
        let text = "---\nperiod: \(iso.string(from: note.period.start))/\(iso.string(from: note.period.end))\n---\n\n\(note.body)\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        onWrite?(note, file)
        return file
    }

    /// The note with this id, of whichever kind; `nil` if there is none or it cannot be read.
    public func note(id: String) -> Note? {
        for kind in NoteKind.allCases {
            if let note = read(folder(kind).appending(path: "\(id).md"), kind: kind) { return note }
        }
        return nil
    }

    /// Removes the note with this id, of whichever kind; no such note is not an error.
    public func delete(id: String) throws {
        for kind in NoteKind.allCases {
            let file = folder(kind).appending(path: "\(id).md")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    /// Notes of `kind` whose period overlaps `period` (touching at an end does not count),
    /// oldest first. Files that do not parse are skipped.
    public func notes(kind: NoteKind, intersecting period: DateInterval) -> [Note] {
        allIDs(kind: kind)
            .compactMap { read(folder(kind).appending(path: "\($0).md"), kind: kind) }
            .filter { $0.period.start < period.end && period.start < $0.period.end }
            .sorted { $0.period.start < $1.period.start }
    }

    /// Ids of every note file of `kind`, sorted.
    public func allIDs(kind: NoteKind) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(kind), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    // MARK: - Files

    private func folder(_ kind: NoteKind) -> URL {
        switch kind {
        case .hourly: return paths.notesHourly
        case .daily: return paths.notesDaily
        case .weekly: return paths.notesWeekly
        }
    }

    private func read(_ file: URL, kind: NoteKind) -> Note? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let parts = text.components(separatedBy: "\n---\n")
        guard parts.count >= 2,
              let line = parts[0].split(separator: "\n").first(where: { $0.hasPrefix("period: ") }) else { return nil }
        let bounds = line.dropFirst("period: ".count).split(separator: "/").map(String.init)
        guard bounds.count == 2,
              let start = iso.date(from: bounds[0]), let end = iso.date(from: bounds[1]), start <= end else { return nil }
        var body = parts.dropFirst().joined(separator: "\n---\n")
        if body.hasPrefix("\n") { body.removeFirst() }
        if body.hasSuffix("\n") { body.removeLast() }
        return Note(kind: kind, id: file.deletingPathExtension().lastPathComponent,
                    period: DateInterval(start: start, end: end), body: body)
    }
}
