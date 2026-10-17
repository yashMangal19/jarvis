import Foundation

/// The recordings already done with, kept in `index/imported.json` as `{ "baseline": true, "paths": [...] }`,
/// so a memo is imported once even though its original stays where it is.
///
/// Path-only, deliberately: a memo is never imported twice, even if it changes in place after import
/// (trimmed in Voice Memos, or a recording that paused long enough to look settled). Re-importing a
/// changed memo would store its lines a second time, and the transcript has no way to replace them.
///
/// Baseline (backlog decision A): the first time the folder is readable, every memo already there is
/// recorded as seen without being imported, so only memos that appear afterwards are imported.
/// Old memos can still be imported by hand through `~/Jarvis/inbox`.
public final class ImportLedger {
    private struct Stored: Codable {
        var baseline: Bool
        var paths: Set<String>
    }

    /// The format before baselines existed: `{ path: { size, mtime } }`. Its paths are kept; it has no baseline.
    private struct LegacyEntry: Decodable {}

    private let file: URL
    private let lock = NSLock()
    private var stored: Stored

    /// A missing or unreadable ledger reads as empty, with no baseline.
    public init(paths: JarvisPaths) {
        file = paths.index.appending(path: "imported.json")
        let data = try? Data(contentsOf: file)
        if let data, let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            self.stored = stored
        } else if let data, let legacy = try? JSONDecoder().decode([String: LegacyEntry].self, from: data) {
            stored = Stored(baseline: false, paths: Set(legacy.keys))
        } else {
            stored = Stored(baseline: false, paths: [])
        }
    }

    /// True once `url` is imported, or was recorded in the baseline.
    public func isImported(_ url: URL) -> Bool {
        lock.withLock { stored.paths.contains(url.standardizedFileURL.path) }
    }

    /// Whether the baseline has been taken.
    public var hasBaseline: Bool { lock.withLock { stored.baseline } }

    /// Adds `url` and rewrites the file.
    public func record(_ url: URL) throws {
        try update { $0.paths.insert(url.standardizedFileURL.path) }
    }

    /// Records every one of `urls` as seen and marks the baseline taken, in one write.
    public func recordBaseline(_ urls: [URL]) throws {
        try update {
            $0.paths.formUnion(urls.map(\.standardizedFileURL.path))
            $0.baseline = true
        }
    }

    /// Applies `change` in memory, then rewrites the file. A failed write still keeps the change in memory.
    private func update(_ change: (inout Stored) -> Void) throws {
        try lock.withLock {
            change(&stored)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: file, options: .atomic)
        }
    }
}
