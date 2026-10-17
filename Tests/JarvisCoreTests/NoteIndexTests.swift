import Foundation
import Testing
import JarvisCore

/// Deterministic embedder: each axis is a set of synonyms; a text scores 1 on every axis it mentions.
struct IndexKeywordEmbedder: Embedder {
    var axes: [Set<String>] = [["budget", "money", "spend", "spent"], ["lunch", "food", "eat", "ate"], ["standup", "meeting"]]

    func embed(_ text: String) throws -> [Float] {
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return axes.map { $0.isDisjoint(with: words) ? 0 : 1 }
    }
}

@Suite struct NoteIndexTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-\(UUID().uuidString)")
    var paths: JarvisPaths { JarvisPaths(root: root) }

    func indexNote(_ id: String, _ body: String) -> Note {
        Note(kind: .hourly, id: id, period: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 3600), body: body)
    }

    @Test func aRewordedQueryFindsTheMatchingNoteFirst() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder())
        try index.add(noteID: "2026-10-17-09", text: "Budget review: we cut the travel line")
        try index.add(noteID: "2026-10-17-13", text: "Lunch with Priya at the canteen")

        let hits = try index.search("how much money did we spend", k: 2)

        #expect(hits.first?.noteID == "2026-10-17-09")
        #expect(hits.first?.score == 1)
    }

    @Test func zeroVectorsAndOtherLengthsAreNotStoredAndNeverScoredAsNaN() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder())
        try index.add(noteID: "lunch", text: "lunch")
        try index.add(noteID: "silence", text: "")
        let shorter = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(axes: [["budget"]]))
        try shorter.add(noteID: "other-model", text: "budget")

        let reopened = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder())
        #expect(try reopened.search("", k: 5).isEmpty)
        #expect(try shorter.search("budget", k: 5).isEmpty)
        let hits = try reopened.search("ate food", k: 5)
        #expect(hits.map(\.noteID) == ["lunch"])
        #expect(hits.allSatisfy { !$0.score.isNaN })
        #expect(!reopened.contains(noteID: "silence") && !reopened.contains(noteID: "other-model"))
    }

    @Test func aRemovedNoteIsNoLongerFound() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder())
        try index.add(noteID: "lunch", text: "lunch")

        try index.remove(noteID: "lunch")

        #expect(try NoteIndex(paths: paths, embedder: IndexKeywordEmbedder()).search("food").isEmpty)
    }

    @Test func rebuildIndexesNotesWrittenBeforeAttachAndAttachIndexesNewOnes() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(paths: paths)
        try store.write(indexNote("2026-10-17-09", "Budget review"))
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder())
        index.attach(to: store)

        try index.rebuild(from: store)
        try store.write(indexNote("2026-10-17-13", "Lunch with Priya"))

        #expect(try index.search("money", k: 1).map(\.noteID) == ["2026-10-17-09"])
        #expect(try index.search("food", k: 1).map(\.noteID) == ["2026-10-17-13"])
    }

    @Test func anEmbedderOfAnotherDimensionRebuildsEveryNote() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(paths: paths)
        try store.write(indexNote("2026-10-17-09", "Budget review"))
        try store.write(indexNote("2026-10-17-13", "Lunch with Priya"))
        try NoteIndex(paths: paths, embedder: IndexKeywordEmbedder()).rebuild(from: store)
        let fallback = IndexKeywordEmbedder(axes: [["lunch", "food"], ["budget", "money"]])

        let index = NoteIndex(paths: paths, embedder: fallback)
        try index.rebuild(from: store)

        #expect(try index.search("food", k: 1).map(\.noteID) == ["2026-10-17-13"])
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.index.appending(path: "vectors.json"))) as? [String: Any]
        #expect(file?["dimension"] as? Int == 2)
        #expect((file?["entries"] as? [String: [Double]])?.keys.sorted() == ["2026-10-17-09", "2026-10-17-13"])
    }
}
