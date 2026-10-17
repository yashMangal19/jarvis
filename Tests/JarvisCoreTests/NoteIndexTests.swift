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

/// `IndexKeywordEmbedder`, except that it throws for the texts in `failing` and first calls `onEmbed`.
final class ScriptedEmbedder: Embedder {
    var failing: Set<String> = []
    var onEmbed: ((String) -> Void)?

    func embed(_ text: String) throws -> [Float] {
        onEmbed?(text)
        if failing.contains(text) { throw CocoaError(.featureUnsupported) }
        return try IndexKeywordEmbedder().embed(text)
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
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        try index.add(noteID: "2026-10-17-09", text: "Budget review: we cut the travel line")
        try index.add(noteID: "2026-10-17-13", text: "Lunch with Priya at the canteen")

        let hits = try index.search("how much money did we spend", k: 2)

        #expect(hits.first?.noteID == "2026-10-17-09")
        #expect(hits.first?.score == 1)
    }

    @Test func zeroVectorsAndOtherLengthsAreNotStoredAndNeverScoredAsNaN() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        try index.add(noteID: "lunch", text: "lunch")
        try index.add(noteID: "silence", text: "")
        let shorter = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(axes: [["budget"]]), embedderID: "keyword")
        try shorter.add(noteID: "other-model", text: "budget")

        let reopened = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        #expect(try reopened.search("", k: 5).isEmpty)
        #expect(try shorter.search("budget", k: 5).isEmpty)
        let hits = try reopened.search("ate food", k: 5)
        #expect(hits.map(\.noteID) == ["lunch"])
        #expect(hits.allSatisfy { !$0.score.isNaN })
        #expect(!reopened.contains(noteID: "silence") && !reopened.contains(noteID: "other-model"))
    }

    @Test func aRemovedNoteIsNoLongerFound() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        try index.add(noteID: "lunch", text: "lunch")

        try index.remove(noteID: "lunch")

        #expect(try NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword").search("food").isEmpty)
    }

    @Test func rebuildIndexesNotesWrittenBeforeAttachAndAttachIndexesNewOnes() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(paths: paths)
        try store.write(indexNote("2026-10-17-09", "Budget review"))
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
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
        try NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword").rebuild(from: store)
        let fallback = IndexKeywordEmbedder(axes: [["lunch", "food"], ["budget", "money"]])

        let index = NoteIndex(paths: paths, embedder: fallback, embedderID: "keyword")
        try index.rebuild(from: store)

        #expect(try index.search("food", k: 1).map(\.noteID) == ["2026-10-17-13"])
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.index.appending(path: "vectors.json"))) as? [String: Any]
        #expect(file?["dimension"] as? Int == 2)
        #expect((file?["entries"] as? [String: Any])?.keys.sorted() == ["2026-10-17-09", "2026-10-17-13"])
    }

    @Test func aNoteWhoseEmbedThrowsIsSkippedAndTheNotesAfterItAreIndexedAndSaved() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(paths: paths)
        try store.write(indexNote("2026-10-17-09", "Budget review"))
        try store.write(indexNote("2026-10-17-10", "Lunch with Priya"))
        try store.write(indexNote("2026-10-17-11", "Standup moved"))
        let embedder = ScriptedEmbedder()
        embedder.failing = ["Budget review"]

        try NoteIndex(paths: paths, embedder: embedder, embedderID: "keyword").rebuild(from: store)

        let reopened = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        #expect(!reopened.contains(noteID: "2026-10-17-09"))
        #expect(reopened.contains(noteID: "2026-10-17-10") && reopened.contains(noteID: "2026-10-17-11"))
    }

    @Test func rebuildReembedsANoteReplacedSinceItsVectorWasStored() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(paths: paths)
        try store.write(indexNote("2026-10-17-09", "Budget review"))
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        try index.rebuild(from: store)
        try store.write(indexNote("2026-10-17-09", "Lunch with Priya"))

        try index.rebuild(from: store)

        let hits = try index.search("food", k: 1)
        #expect(hits.map(\.noteID) == ["2026-10-17-09"])
        #expect(hits.first?.score == 1)
    }

    @Test func rebuildDropsTheVectorOfANoteThatNoLongerExists() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(paths: paths)
        try store.write(indexNote("2026-10-17-09", "Budget review"))
        try store.write(indexNote("2026-10-17-13", "Lunch with Priya"))
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        try index.rebuild(from: store)
        try store.delete(id: "2026-10-17-13")

        try index.rebuild(from: store)

        #expect(!index.contains(noteID: "2026-10-17-13"))
        #expect(!NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword").contains(noteID: "2026-10-17-13"))
    }

    @Test func aRebuildThatReadAnOlderBodyKeepsTheVectorOfAWriteDuringIt() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(paths: paths)
        try store.write(indexNote("2026-10-17-09", "Budget review"))
        let embedder = ScriptedEmbedder()
        let index = NoteIndex(paths: paths, embedder: embedder, embedderID: "keyword")
        index.attach(to: store)
        // While rebuild embeds the old body, the note is rewritten and indexed by the write hook.
        embedder.onEmbed = { [unowned embedder] text in
            guard text == "Budget review" else { return }
            embedder.onEmbed = nil
            _ = try? store.write(indexNote("2026-10-17-09", "Lunch with Priya"))
        }

        try index.rebuild(from: store)

        let hits = try index.search("food", k: 1)
        #expect(hits.map(\.noteID) == ["2026-10-17-09"])
        #expect(hits.first?.score == 1)
    }

    @Test func vectorsOnDiskWithNoDirectionAreDroppedAndKOfZeroOrLessFindsNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        try index.add(noteID: "lunch", text: "lunch")
        try index.add(noteID: "budget", text: "budget")
        try index.add(noteID: "standup", text: "standup")
        let url = paths.index.appending(path: "vectors.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try #require(json["entries"] as? [String: [String: Any]])
        entries["lunch"]?["vector"] = [0, 0, 0]
        entries["standup"]?["vector"] = [0, 0, 3e38]
        json["entries"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let reopened = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")

        #expect(!reopened.contains(noteID: "lunch") && !reopened.contains(noteID: "standup"))
        #expect(try reopened.search("budget lunch standup", k: 5).map(\.noteID) == ["budget"])
        #expect(try reopened.search("budget", k: 0).isEmpty)
        #expect(try reopened.search("budget", k: -1).isEmpty)
    }

    /// The same three axes in another order: same dimension, different vectors.
    let otherModel = IndexKeywordEmbedder(axes: [["standup", "meeting"], ["budget", "money"], ["lunch", "food"]])

    @Test func anotherEmbedderOfTheSameDimensionRebuildsEveryNote() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(paths: paths)
        try store.write(indexNote("2026-10-17-09", "Budget review"))
        try store.write(indexNote("2026-10-17-13", "Lunch with Priya"))
        try NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "Core AI").rebuild(from: store)

        let index = NoteIndex(paths: paths, embedder: otherModel, embedderID: "NaturalLanguage")
        try index.rebuild(from: store)

        let hits = try index.search("food", k: 1)
        #expect(hits.map(\.noteID) == ["2026-10-17-13"] && hits.first?.score == 1)
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.index.appending(path: "vectors.json"))) as? [String: Any]
        #expect(file?["embedder"] as? String == "NaturalLanguage")
    }

    @Test func aFileThatDoesNotNameItsEmbedderIsRebuiltFromScratch() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(paths: paths)
        try store.write(indexNote("2026-10-17-09", "Budget review"))
        try store.write(indexNote("2026-10-17-13", "Lunch with Priya"))
        try NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "Core AI").rebuild(from: store)
        let url = paths.index.appending(path: "vectors.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["embedder"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let index = NoteIndex(paths: paths, embedder: otherModel, embedderID: "Core AI")
        try index.rebuild(from: store)

        let hits = try index.search("food", k: 1)
        #expect(hits.map(\.noteID) == ["2026-10-17-13"] && hits.first?.score == 1)
    }
}
