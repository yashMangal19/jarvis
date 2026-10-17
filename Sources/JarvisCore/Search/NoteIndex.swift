import Accelerate
import Foundation

/// One vector per note in `index/vectors.json` (D-6), searched by cosine similarity.
///
/// A vector with no direction (zero norm) or a length other than the file's `dimension` is not
/// stored, so the note stays absent and the next `rebuild` retries it.
public final class NoteIndex {
    private struct File: Codable {
        var dimension: Int
        var entries: [String: [Float]]
    }

    private let embedder: any Embedder
    private let url: URL
    private let lock = NSLock()
    private var file: File

    public init(paths: JarvisPaths, embedder: any Embedder) {
        self.embedder = embedder
        url = paths.index.appending(path: "vectors.json")
        // A missing or unreadable file is an empty index; `rebuild` refills it from the notes.
        file = (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url))) ?? File(dimension: 0, entries: [:])
    }

    public func contains(noteID: String) -> Bool {
        lock.withLock { file.entries[noteID] != nil }
    }

    public func add(noteID: String, text: String) throws {
        let vector = try embedder.embed(text)
        try lock.withLock {
            if insert(noteID, vector) { try save() }
        }
    }

    public func remove(noteID: String) throws {
        try lock.withLock {
            guard file.entries.removeValue(forKey: noteID) != nil else { return }
            try save()
        }
    }

    /// Indexes every note of `notes` missing from the file. If the embedder's vectors are now of
    /// another length (e.g. a Core AI → NaturalLanguage fallback), every vector is dropped first.
    public func rebuild(from notes: NoteStore) throws {
        let dimension = try embedder.embed(Self.probe).count
        var changed = lock.withLock {
            guard !file.entries.isEmpty, dimension != file.dimension else { return false }
            file = File(dimension: dimension, entries: [:])
            return true
        }
        for id in NoteKind.allCases.flatMap(notes.allIDs) where !contains(noteID: id) {
            guard let note = notes.note(id: id) else { continue }
            let vector = try embedder.embed(note.body)
            if lock.withLock({ insert(id, vector) }) { changed = true }
        }
        // One write for the whole pass: the file is rewritten whole (D-6), so per-note saves are quadratic.
        if changed { try lock.withLock { try save() } }
    }

    /// Indexes each note as `notes` writes it, after any hook already set. A failed embed or save
    /// is dropped here (the hook cannot throw); the note stays absent and the next `rebuild` retries it.
    public func attach(to notes: NoteStore) {
        let previous = notes.onWrite
        notes.onWrite = { [weak self] note, url in
            previous?(note, url)
            try? self?.add(noteID: note.id, text: note.body)
        }
    }

    /// The `k` best notes for `query`, best first. Entries of another length are skipped.
    public func search(_ query: String, k: Int = 5) throws -> [(noteID: String, score: Float)] {
        let q = try embedder.embed(query)
        let qNorm = Self.norm(q)
        guard qNorm > 0 else { return [] }
        let entries = lock.withLock { file.entries }
        return entries
            .filter { $0.value.count == q.count }
            .map { id, e in (noteID: id, score: vDSP.dot(q, e) / (qNorm * Self.norm(e))) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.noteID < $1.noteID }
            .prefix(k).map { $0 }
    }

    /// Any non-empty text: only the length of its vector is read.
    private static let probe = "Jarvis note index"

    private static func norm(_ v: [Float]) -> Float {
        vDSP.sumOfSquares(v).squareRoot()
    }

    /// Stores `vector` unless it has no direction or another length than the stored ones.
    /// Caller holds `lock`.
    private func insert(_ noteID: String, _ vector: [Float]) -> Bool {
        guard Self.norm(vector) > 0, file.entries.isEmpty || vector.count == file.dimension else { return false }
        file.dimension = vector.count
        file.entries[noteID] = vector
        return true
    }

    /// Caller holds `lock`.
    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: url, options: .atomic)
    }
}
