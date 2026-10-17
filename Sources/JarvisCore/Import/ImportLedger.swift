import Foundation

/// The recordings already imported, kept in `index/imported.json` as `{ path: { size, mtime } }`,
/// so a memo is imported once even though its original stays where it is.
public final class ImportLedger {
    private struct Entry: Codable {
        let size: Int?
        let mtime: Date?
    }

    private let file: URL
    private let lock = NSLock()
    private var entries: [String: Entry]

    /// A missing or unreadable ledger reads as empty.
    public init(paths: JarvisPaths) {
        file = paths.index.appending(path: "imported.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        entries = (try? decoder.decode([String: Entry].self, from: Data(contentsOf: file))) ?? [:]
    }

    public func isImported(_ url: URL) -> Bool {
        lock.withLock { entries[url.standardizedFileURL.path] != nil }
    }

    /// Adds `url` with its current size and modification date, and rewrites the file.
    public func record(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let entry = Entry(size: values?.fileSize, mtime: values?.contentModificationDate)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try lock.withLock {
            entries[url.standardizedFileURL.path] = entry
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(entries).write(to: file, options: .atomic)
        }
    }
}
