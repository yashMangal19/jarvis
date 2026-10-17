import Foundation

public struct MemoryAnswer: Equatable {
    public let text: String
    /// The notes given to the model, best match first.
    public let usedNoteIDs: [String]

    public init(text: String, usedNoteIDs: [String]) {
        self.text = text
        self.usedNoteIDs = usedNoteIDs
    }
}

/// Answers a question from the best-matching notes through the `NoteWriter`'s model (D-4).
public struct MemorySearch {
    private let index: NoteIndex
    private let notes: NoteStore
    private let writer: () -> (any NoteWriter)?
    private let prompts: PromptStore

    public init(index: NoteIndex, notes: NoteStore, writer: @escaping () -> (any NoteWriter)?, prompts: PromptStore) {
        self.index = index
        self.notes = notes
        self.writer = writer
        self.prompts = prompts
    }

    public func answer(_ question: String) async throws -> MemoryAnswer {
        // A score of 0 or less shares nothing with the question, so it is not a match.
        let hits = try index.search(question).filter { $0.score > 0 }
            .compactMap { hit in notes.note(id: hit.noteID) }
        guard !hits.isEmpty else { return MemoryAnswer(text: "I have no notes about that.", usedNoteIDs: []) }
        guard let writer = writer() else {
            return MemoryAnswer(text: "Notes are off — install Claude Code or Ollama to ask questions.", usedNoteIDs: [])
        }
        let context = hits.map { "### \($0.id)\n\($0.body)" }.joined(separator: "\n\n")
        let text = try await writer.note(from: context, prompt: try prompts.prompt(.answer) + "\n\nQuestion: " + question)
        return MemoryAnswer(text: text, usedNoteIDs: hits.map(\.id))
    }
}
