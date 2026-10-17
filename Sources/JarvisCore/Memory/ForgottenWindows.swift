import Foundation

/// Windows the user forgot, in `index/forgotten.json`, so speech still in flight when they forgot
/// (a chunk transcribing, a note with the writer) is dropped instead of landing in the window.
///
/// One instance is shared by everything that writes transcript lines or notes: `record` and
/// `unlessForgotten` hold one lock, so a write either finishes before a window is recorded (and
/// `ForgetLastHour` then deletes it) or sees the window and is skipped.
public final class ForgottenWindows {
    private struct Window: Codable {
        var start: Date
        var end: Date
    }

    /// Transcripts are kept 7 days, counted from the start of a local day; 8 covers every line
    /// a window could still match.
    private static let retention: TimeInterval = 8 * 86_400

    private let url: URL
    private let lock = NSLock()
    private var windows: [Window]

    public init(paths: JarvisPaths) {
        url = paths.index.appending(path: "forgotten.json")
        windows = (try? JSONDecoder().decode([Window].self, from: Data(contentsOf: url))) ?? []
    }

    /// Adds `window` (half-open, like `TranscriptStore.lines(in:)`) and saves, dropping windows
    /// that ended more than the retention before `now`. Throws, keeping nothing new, if the save fails.
    public func record(_ window: DateInterval, now: Date) throws {
        try lock.withLock {
            let kept = windows.filter { $0.end > now.addingTimeInterval(-Self.retention) }
                + [Window(start: window.start, end: window.end)]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(kept).write(to: url, options: .atomic)
            windows = kept
        }
    }

    public func contains(_ time: Date) -> Bool {
        lock.withLock { isForgotten(time) }
    }

    /// Runs `body` only if none of `times` is forgotten, holding the lock throughout; `nil` if one is.
    public func unlessForgotten<T>(_ times: [Date], _ body: () throws -> T) rethrows -> T? {
        try lock.withLock {
            times.contains(where: isForgotten) ? nil : try body()
        }
    }

    /// Caller holds `lock`.
    private func isForgotten(_ time: Date) -> Bool {
        windows.contains { $0.start <= time && time < $0.end }
    }
}
