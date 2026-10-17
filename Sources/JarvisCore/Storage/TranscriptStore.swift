import Foundation

/// One labelled line of a transcript.
public struct TranscriptLine: Codable, Equatable {
    public let time: Date
    public let label: SpeakerLabel
    public let text: String

    public init(time: Date, label: SpeakerLabel, text: String) {
        self.time = time
        self.label = label
        self.text = text
    }
}

extension SpeakerLabel: Codable {}

/// `transcripts/YYYY-MM-DD.jsonl`: one JSON object per line, one file per local calendar day.
/// Times are stored as ISO-8601 to the whole second.
public final class TranscriptStore {
    private let paths: JarvisPaths
    private let calendar: Calendar
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(paths: JarvisPaths, calendar: Calendar = .current) {
        self.paths = paths
        self.calendar = calendar
    }

    /// Appends `line` to the file of its local day, creating the folder and file on first write.
    public func append(_ line: TranscriptLine) throws {
        let data = try encodeLine(line)
        let file = dayFile(for: line.time)
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            try fm.createDirectory(at: paths.transcripts, withIntermediateDirectories: true)
            try data.write(to: file)
            return
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Lines with `window.start <= time < window.end`, oldest first. Half-open so adjacent
    /// windows (hour after hour) never share a line.
    public func lines(in window: DateInterval) throws -> [TranscriptLine] {
        try dayFiles(touching: window)
            .flatMap(read)
            .filter { contains(window, $0.time) }
            .sorted { $0.time < $1.time }
    }

    /// Rewrites each day file the window touches without its lines; a file left empty is removed.
    public func deleteLines(in window: DateInterval) throws {
        for file in dayFiles(touching: window) {
            let all = try read(file)
            let kept = all.filter { !contains(window, $0.time) }
            if kept.count == all.count { continue }
            if kept.isEmpty {
                try FileManager.default.removeItem(at: file)
            } else {
                try Data(kept.map(encodeLine).joined()).write(to: file, options: .atomic)
            }
        }
    }

    /// Removes day files whose day is before the local day `days` days before `now`
    /// (with 7: on the 17th, the 9th goes and the 10th stays). Looks only inside `transcripts/`.
    public func purge(olderThan days: Int = 7, now: Date) throws -> [URL] {
        guard let shifted = calendar.date(byAdding: .day, value: -days, to: now) else { return [] }
        let cutoffDay = calendar.startOfDay(for: shifted)
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.transcripts.path) else { return [] }
        var removed: [URL] = []
        for file in try fm.contentsOfDirectory(at: paths.transcripts, includingPropertiesForKeys: nil) {
            guard let day = day(ofFile: file), day < cutoffDay else { continue }
            try fm.removeItem(at: file)
            removed.append(file)
        }
        return removed
    }

    // MARK: - Files

    private func contains(_ window: DateInterval, _ time: Date) -> Bool {
        window.start <= time && time < window.end
    }

    private func dayFile(for time: Date) -> URL {
        let c = calendar.dateComponents([.year, .month, .day], from: time)
        let name = String(format: "%04d-%02d-%02d.jsonl", c.year!, c.month!, c.day!)
        return paths.transcripts.appending(path: name)
    }

    /// The start of the local day a `YYYY-MM-DD.jsonl` name stands for; `nil` for any other file.
    private func day(ofFile file: URL) -> Date? {
        guard file.pathExtension == "jsonl" else { return nil }
        let parts = file.deletingPathExtension().lastPathComponent.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Existing day files from the window's first local day through the day holding its end.
    private func dayFiles(touching window: DateInterval) -> [URL] {
        var files: [URL] = []
        var day = calendar.startOfDay(for: window.start)
        while day <= window.end {
            let file = dayFile(for: day)
            if FileManager.default.fileExists(atPath: file.path) { files.append(file) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return files
    }

    private func read(_ file: URL) throws -> [TranscriptLine] {
        try Data(contentsOf: file)
            .split(separator: UInt8(ascii: "\n"))
            .map { try decoder.decode(TranscriptLine.self, from: Data($0)) }
    }

    private func encodeLine(_ line: TranscriptLine) throws -> Data {
        var data = try encoder.encode(line)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
