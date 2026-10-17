import Accelerate
import CryptoKit
import Foundation

/// One vector per note in `index/vectors.json` (D-6), searched by cosine similarity.
///
/// A vector with no direction (zero or non-finite norm) or a length other than the file's `dimension` is not
/// stored, so the note stays absent and the next `rebuild` retries it.
///
/// One instance owns `vectors.json`: two instances on the same file each save their own copy and
/// overwrite each other's updates. Within one instance, a vector is replaced only by one embedded
/// from text read later, so a slow `rebuild` never overwrites the vector of a newer `add`.
public final class NoteIndex {
    private struct File: Codable {
        /// The name of the embedder that wrote every vector; `nil` in a file from before it was kept.
        var embedder: String?
        var dimension: Int
        var entries: [String: Entry]
    }

    private struct Entry: Codable {
        var vector: [Float]
        /// SHA-256 of the embedded text: `rebuild` re-embeds a note whose text no longer matches.
        var digest: String
    }

    private let embedder: any Embedder
    private let url: URL
    private let lock = NSLock()
    private var file: File
    /// Changes not yet in `vectors.json`, e.g. after a failed save.
    private var unsaved = false
    /// When each entry's text was read, from `clock`; in memory only, since one instance owns the file.
    private var readAt: [String: Int] = [:]
    private var clock = 0

    /// `embedderID` names the embedder (the search name on the Engines line). Vectors written by
    /// another embedder, or by one the file does not name, are dropped, and `rebuild` re-embeds every note.
    public init(paths: JarvisPaths, embedder: any Embedder, embedderID: String) {
        self.embedder = embedder
        url = paths.index.appending(path: "vectors.json")
        // A missing or unreadable file is an empty index; `rebuild` refills it from the notes.
        let stored = try? JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        file = stored.flatMap { $0.embedder == embedderID ? $0 : nil } ?? File(embedder: embedderID, dimension: 0, entries: [:])
        unsaved = stored != nil && stored?.embedder != embedderID
        // The file is not trusted to hold only scorable vectors; a dropped one is re-embedded by `rebuild`.
        file.entries = file.entries.filter { [dimension = file.dimension] in
            Self.hasDirection($0.value.vector) && $0.value.vector.count == dimension
        }
    }

    public func contains(noteID: String) -> Bool {
        lock.withLock { file.entries[noteID] != nil }
    }

    public func add(noteID: String, text: String) throws {
        let readAt = tick()
        let vector = try embedder.embed(text)
        try lock.withLock {
            insert(noteID, Entry(vector: vector, digest: Self.digest(text)), readAt: readAt)
            if unsaved { try save() }
        }
    }

    public func remove(noteID: String) throws {
        try lock.withLock {
            guard file.entries.removeValue(forKey: noteID) != nil else { return }
            unsaved = true
            try save()
        }
    }

    /// Makes the index match `notes`: embeds every note that is missing or whose text changed since
    /// it was embedded, and drops the vectors of notes that no longer exist. A note whose embed
    /// throws is skipped and keeps its previous state. If the embedder's vectors are now of another
    /// length (e.g. a Core AI → NaturalLanguage fallback), every vector is dropped first.
    public func rebuild(from notes: NoteStore) throws {
        let dimension = try embedder.embed(Self.probe).count
        let ids = NoteKind.allCases.flatMap(notes.allIDs)
        lock.withLock {
            if !file.entries.isEmpty, dimension != file.dimension {
                file = File(embedder: file.embedder, dimension: dimension, entries: [:])
                unsaved = true
            }
            let gone = Set(file.entries.keys).subtracting(ids)
            for id in gone { file.entries[id] = nil }
            if !gone.isEmpty { unsaved = true }
        }
        for id in ids {
            let readAt = tick()
            guard let note = notes.note(id: id) else { continue }
            let digest = Self.digest(note.body)
            guard lock.withLock({ file.entries[id]?.digest != digest }),
                  let vector = try? embedder.embed(note.body) else { continue }
            lock.withLock { insert(id, Entry(vector: vector, digest: digest), readAt: readAt) }
        }
        // One write for the whole pass: the file is rewritten whole (D-6), so per-note saves are quadratic.
        try lock.withLock { if unsaved { try save() } }
    }

    /// Indexes each note as `notes` writes it, after any hook already set. A failed embed or save
    /// is dropped here (the hook cannot throw); the note keeps its previous vector, or stays absent,
    /// and the next `rebuild` re-embeds it because its text no longer matches what was embedded.
    public func attach(to notes: NoteStore) {
        let previous = notes.onWrite
        notes.onWrite = { [weak self] note, url in
            previous?(note, url)
            try? self?.add(noteID: note.id, text: note.body)
        }
    }

    /// The `k` best notes for `query`, best first. Entries of another length are skipped.
    public func search(_ query: String, k: Int = 5) throws -> [(noteID: String, score: Float)] {
        guard k > 0 else { return [] }
        let q = try embedder.embed(query)
        let qNorm = Self.norm(q)
        guard qNorm > 0 else { return [] }
        let entries = lock.withLock { file.entries }
        return entries
            .filter { $0.value.vector.count == q.count }
            .map { id, e in (noteID: id, score: vDSP.dot(q, e.vector) / (qNorm * Self.norm(e.vector))) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.noteID < $1.noteID }
            .prefix(k).map { $0 }
    }

    /// Any non-empty text: only the length of its vector is read.
    private static let probe = "Jarvis note index"

    private static func norm(_ v: [Float]) -> Float {
        vDSP.sumOfSquares(v).squareRoot()
    }

    /// A positive, finite norm: a cosine with it is a number, never NaN or 0 by overflow.
    private static func hasDirection(_ v: [Float]) -> Bool {
        let n = norm(v)
        return n > 0 && n.isFinite
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func tick() -> Int {
        lock.withLock {
            clock += 1
            return clock
        }
    }

    /// Stores `entry` unless its vector has no direction or another length than the stored ones,
    /// or the stored vector was embedded from text read later. Caller holds `lock`.
    private func insert(_ noteID: String, _ entry: Entry, readAt: Int) {
        guard Self.hasDirection(entry.vector), file.entries.isEmpty || entry.vector.count == file.dimension,
              self.readAt[noteID].map({ $0 < readAt }) ?? true else { return }
        file.dimension = entry.vector.count
        file.entries[noteID] = entry
        self.readAt[noteID] = readAt
        unsaved = true
    }

    /// Caller holds `lock`.
    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: url, options: .atomic)
        unsaved = false
    }
}
