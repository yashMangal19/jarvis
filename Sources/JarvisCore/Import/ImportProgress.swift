import Foundation

/// Where each recording's import got to, kept in `index/import-progress.json` so a relaunch carries on (J-023,
/// DEC-52): how many of its chunks are stored, and whether all are (only its delete is left). Keyed by the file's
/// version (path, size, modification date), so a different recording under the same name starts afresh. Written
/// after every stored chunk; a crash between a chunk's line and this write can repeat that one chunk at most.
public final class ImportProgress {
    private struct Entry: Codable {
        var stored: Int
        var complete: Bool
    }

    private let file: URL?
    private let lock = NSLock()
    private var entries: [String: Entry]

    /// `file` nil keeps progress in memory only. Entries for files that no longer exist are dropped on load.
    public init(file: URL?) {
        self.file = file
        let loaded = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = loaded.filter { key, _ in
            FileManager.default.fileExists(atPath: String(key.prefix { $0 != "\u{1F}" }))
        }
    }

    public var isEmpty: Bool { lock.withLock { entries.isEmpty } }

    func stored(_ stamp: FileStamp) -> Int { lock.withLock { entries[Self.key(stamp)]?.stored ?? 0 } }
    func isComplete(_ stamp: FileStamp) -> Bool { lock.withLock { entries[Self.key(stamp)]?.complete ?? false } }

    func setStored(_ count: Int, for stamp: FileStamp) throws {
        try update { $0[Self.key(stamp), default: Entry(stored: 0, complete: false)].stored = count }
    }

    func setComplete(_ stamp: FileStamp) throws {
        try update { $0[Self.key(stamp), default: Entry(stored: 0, complete: false)].complete = true }
    }

    func clear(_ stamp: FileStamp) throws {
        try update { $0[Self.key(stamp)] = nil }
    }

    /// Path, then size and modification date, separated by a character no path holds.
    private static func key(_ stamp: FileStamp) -> String {
        "\(stamp.path)\u{1F}\(stamp.size ?? -1)\u{1F}\(stamp.modified?.timeIntervalSinceReferenceDate ?? -1)"
    }

    /// Applies `change` in memory, then rewrites the file. A failed write still keeps the change in memory.
    private func update(_ change: (inout [String: Entry]) -> Void) throws {
        try lock.withLock {
            change(&entries)
            guard let file else { return }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
        }
    }
}
