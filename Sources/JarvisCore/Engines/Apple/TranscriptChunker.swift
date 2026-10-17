/// Splits a transcript into pieces small enough for a model's context.
public enum TranscriptChunker {
    /// Splits `text` on line boundaries, never mid-line, so each chunk is at most `maxCharacters`
    /// long. A single line longer than `maxCharacters` becomes its own (oversized) chunk.
    /// `chunks(...).joined(separator: "\n")` gives back `text`.
    public static func chunks(_ text: String, maxCharacters: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !current.isEmpty, current.count + 1 + line.count > maxCharacters {
                chunks.append(current)
                current = String(line)
            } else {
                current = current.isEmpty ? String(line) : current + "\n" + line
            }
        }
        chunks.append(current)
        return chunks
    }
}
