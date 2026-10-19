import Foundation

/// The recordings already done with, kept in `index/imported.json` as
/// `{ "baseline": true, "paths": [...], "undecodable": { path: { size, modified } } }`, so a memo is imported
/// once even though its original stays where it is.
///
/// Imported is path-only, deliberately: a memo is never imported twice, even if it changes in place after
/// import (trimmed in Voice Memos). Re-importing a changed memo would store its lines a second time, and the
/// transcript has no way to replace them.
///
/// Undecodable is a verdict on one version (size and modification date), never on the path (J-019, DEC-48).
/// A memo still being written looks broken, so a memo given up on is a candidate again as soon as it changes,
/// at the next scan or launch. No stall of its writer, however long, can lose it.
///
/// Baseline (backlog decision A): the first time the folder is readable, every memo already there is
/// recorded as seen without being imported, so only memos that appear afterwards are imported.
/// Old memos can still be imported by hand through the data home's `inbox` folder.
public final class ImportLedger {
    private struct Stored: Codable {
        var baseline: Bool
        var paths: Set<String>
        /// Absent in ledgers written before J-019.
        var undecodable: [String: Version]?
    }

    private struct Version: Codable, Equatable {
        var size: Int?
        var modified: Date?
        init(_ stamp: FileStamp) { size = stamp.size; modified = stamp.modified }
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
            stored = Stored(baseline: false, paths: Set(legacy.keys), undecodable: nil)
        } else {
            stored = Stored(baseline: false, paths: [], undecodable: nil)
        }
    }

    /// True once `url` is imported or in the baseline, or when this very version was found undecodable.
    public func isImported(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return lock.withLock {
            if stored.paths.contains(path) { return true }
            guard let verdict = stored.undecodable?[path] else { return false }
            return verdict == Version(FileStamp(url))
        }
    }

    /// Whether the baseline has been taken.
    public var hasBaseline: Bool { lock.withLock { stored.baseline } }

    /// Adds `url` and rewrites the file.
    public func record(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        try update {
            $0.paths.insert(path)
            $0.undecodable?[path] = nil
        }
    }

    /// Records that `url`, as it was at `stamp`, does not decode. Any later version of it is new again.
    func recordUndecodable(_ url: URL, as stamp: FileStamp) throws {
        let path = url.standardizedFileURL.path
        try update { $0.undecodable = ($0.undecodable ?? [:]).merging([path: Version(stamp)]) { $1 } }
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
