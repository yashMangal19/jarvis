import Foundation

/// One voice command, from what was heard to how it ended (J-016, DEC-47). It holds what the user said and
/// what Jarvis said back, so it is kept like a transcript: in the data home only, for 7 days, and removed
/// by "Forget the last hour". The unified log gets names only (`Log.command`).
public struct CommandRecord: Codable, Equatable {
    public enum Outcome: String, Codable { case done, cancelled, failed }

    /// When it was heard, to the whole second like `TranscriptLine`.
    public let time: Date
    /// "wake word", "hold" or "reply window".
    public let trigger: String
    /// The input it was heard on.
    public let mic: String?
    public let heard: String
    /// `VoiceIntent`'s case, without what was said: "meetingMode(off)", "toolCommand".
    public internal(set) var intent: String
    public var action: String
    /// What Jarvis said for it: the read-back, then the result or "Cancelled.".
    public var said: [String]
    /// What the user said after the read-back: the yes, no or corrections.
    public var replies: [String]
    public var outcome: Outcome
    public var reason: String?

    public init(time: Date, trigger: String, mic: String?, heard: String, intent: String, action: String,
                said: [String] = [], replies: [String] = [], outcome: Outcome = .done, reason: String? = nil) {
        self.time = Date(timeIntervalSince1970: time.timeIntervalSince1970.rounded(.down))
        self.trigger = trigger
        self.mic = mic
        self.heard = heard
        self.intent = intent
        self.action = action
        self.said = said
        self.replies = replies
        self.outcome = outcome
        self.reason = reason
    }
}

/// `logs/commands.jsonl`: one JSON object per line, oldest first.
public final class CommandLog {
    private let paths: JarvisPaths
    private let calendar: Calendar
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
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

    public func append(_ record: CommandRecord) throws {
        try lock.withLock {
            var data = try encoder.encode(record)
            data.append(UInt8(ascii: "\n"))
            let file = paths.commandLog
            guard FileManager.default.fileExists(atPath: file.path) else {
                try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
                return try data.write(to: file)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
    }

    /// Every record, oldest first; a line that doesn't parse (torn by a crash) is skipped.
    public func records() throws -> [CommandRecord] {
        try lock.withLock { try read() }
    }

    /// Removes the records heard within `window` (half-open, like `TranscriptStore.lines(in:)`).
    public func deleteRecords(in window: DateInterval) throws {
        try rewrite { window.start <= $0.time && $0.time < window.end }
    }

    /// Removes records from before the local day `days` days before `now`, as `TranscriptStore.purge` does
    /// for day files: with 7, on the 17th the 9th goes and the 10th stays.
    public func purge(olderThan days: Int = 7, now: Date) throws {
        guard let shifted = calendar.date(byAdding: .day, value: -days, to: now) else { return }
        let cutoff = calendar.startOfDay(for: shifted)
        try rewrite { $0.time < cutoff }
    }

    private func read() throws -> [CommandRecord] {
        guard let data = FileManager.default.contents(atPath: paths.commandLog.path) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(CommandRecord.self, from: Data($0)) }
    }

    private func rewrite(removing remove: (CommandRecord) -> Bool) throws {
        try lock.withLock {
            let all = try read()
            let kept = all.filter { !remove($0) }
            guard kept.count != all.count else { return }
            var data = Data()
            for record in kept {
                data.append(try encoder.encode(record))
                data.append(UInt8(ascii: "\n"))
            }
            try data.write(to: paths.commandLog, options: .atomic)
        }
    }
}
