import Foundation

/// Splits a transcript into pieces small enough for a model's context.
public enum TranscriptChunker {
    /// Splits `text` on line boundaries, never mid-line, so each chunk is at most `maxCharacters`
    /// long. A single line longer than `maxCharacters` becomes its own (oversized) chunk.
    /// Blank lines never start a chunk: they stay with the chunk before them (or the next one at the
    /// start of `text`), so no chunk is blank and a chunk may run over by its trailing blank lines.
    /// `chunks(...).joined(separator: "\n")` gives back `text`.
    public static func chunks(_ text: String, maxCharacters: Int) -> [String] {
        var chunks: [String] = []
        var current: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let started = current else {
                current = String(line)
                continue
            }
            let blank = line.allSatisfy(\.isWhitespace)
            if !blank, !started.allSatisfy(\.isWhitespace), started.count + 1 + line.count > maxCharacters {
                chunks.append(started)
                current = String(line)
            } else {
                current = started + "\n" + line
            }
        }
        if let current { chunks.append(current) }
        return chunks
    }

    /// Writes one note from `text` with `write`, keeping every call within `maxCharacters`: text that
    /// fits is written in one call; otherwise each chunk gets a partial note and the joined partials
    /// go through the same step again, at most `maxRounds` times.
    public static func reduce(
        _ text: String, maxCharacters: Int, maxRounds: Int = 3,
        write: (String) async throws -> String
    ) async throws -> String {
        var text = text
        for _ in 0..<maxRounds {
            if text.count <= maxCharacters { return try await write(text) }
            var partials: [String] = []
            for chunk in chunks(text, maxCharacters: maxCharacters) {
                partials.append(try await write(chunk))
            }
            text = partials.joined(separator: "\n\n")
        }
        guard text.count <= maxCharacters else { throw TranscriptChunkerError.partialNotesTooLong(rounds: maxRounds) }
        return try await write(text)
    }
}

public enum TranscriptChunkerError: Error, Equatable, LocalizedError {
    case partialNotesTooLong(rounds: Int)

    public var errorDescription: String? {
        switch self {
        case .partialNotesTooLong(let rounds):
            "The transcript is too long to summarise: after \(rounds) rounds of partial notes, they still do not fit the model's context."
        }
    }
}
