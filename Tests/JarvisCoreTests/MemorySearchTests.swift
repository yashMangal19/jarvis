import Foundation
import Testing
import JarvisCore

final class MemoryRecordingWriter: NoteWriter {
    var calls: [(transcript: String, prompt: String)] = []

    func note(from transcript: String, prompt: String) async throws -> String {
        calls.append((transcript, prompt))
        return "You cut the travel line (2026-10-17-09)."
    }
}

@Suite struct MemorySearchTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-\(UUID().uuidString)")
    var paths: JarvisPaths { JarvisPaths(root: root) }

    func memoryNote(_ id: String, _ body: String) -> Note {
        Note(kind: .hourly, id: id, period: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 3600), body: body)
    }

    @Test func theTopNotesGoToTheWriterUnderTheirIdsAndTheAnswerNamesThem() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(paths: paths)
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        index.attach(to: store)
        try store.write(memoryNote("2026-10-17-09", "Budget review: we cut the travel line"))
        try store.write(memoryNote("2026-10-17-11", "Spent the money on lunch"))
        try store.write(memoryNote("2026-10-17-13", "Standup moved to Thursday"))
        let writer = MemoryRecordingWriter()
        let prompts = PromptStore(paths: paths)
        let search = MemorySearch(index: index, notes: store, writer: { writer }, prompts: prompts)

        let answer = try await search.answer("What did we decide about the budget?")

        #expect(answer == MemoryAnswer(text: "You cut the travel line (2026-10-17-09).",
                                       usedNoteIDs: ["2026-10-17-09", "2026-10-17-11"]))
        #expect(writer.calls.map(\.transcript) == [
            "### 2026-10-17-09\nBudget review: we cut the travel line\n\n### 2026-10-17-11\nSpent the money on lunch",
        ])
        #expect(writer.calls.map(\.prompt) == [try prompts.prompt(.answer) + "\n\nQuestion: What did we decide about the budget?"])
    }

    @Test func noMatchingNoteAndNoWriterEachSaySoWithoutCallingTheModel() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(paths: paths)
        let index = NoteIndex(paths: paths, embedder: IndexKeywordEmbedder(), embedderID: "keyword")
        index.attach(to: store)
        try store.write(memoryNote("2026-10-17-13", "Standup moved to Thursday"))
        let writer = MemoryRecordingWriter()
        let prompts = PromptStore(paths: paths)

        let unrelated = try await MemorySearch(index: index, notes: store, writer: { writer }, prompts: prompts)
            .answer("What did we eat?")
        let off = try await MemorySearch(index: index, notes: store, writer: { nil }, prompts: prompts)
            .answer("When is the standup?")

        #expect(unrelated == MemoryAnswer(text: "I have no notes about that.", usedNoteIDs: []))
        #expect(off == MemoryAnswer(text: "Notes are off — install Claude Code or Ollama to ask questions.", usedNoteIDs: []))
        #expect(writer.calls.isEmpty)
    }
}
