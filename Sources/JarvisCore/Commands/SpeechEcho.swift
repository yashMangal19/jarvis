import Foundation

/// What Jarvis itself said, taken out of what the mic heard (J-027, DEC-55). The wake word stays on while Jarvis
/// speaks, so the mic hears Jarvis too. Jarvis knows its own sentences: their words are aligned against what was
/// heard, in order (longest common subsequence), and the aligned words removed. What is left is what someone
/// else said over it. A sentence that names Jarvis cancels out only its own "Jarvis".
///
/// Ceiling: a word the user says that also comes, in order, within Jarvis's sentence can be removed with it.
/// Hardware echo cancellation is the full answer, deferred to after 0.1.0.
enum SpeechEcho {
    /// `heard` without the words aligned to `spoken`, normalised; `heard` as it is when nothing was spoken.
    static func removing(_ spoken: [String], from heard: String) -> String {
        let said = spoken.flatMap(words(of:))
        guard !said.isEmpty else { return heard }
        let words = words(of: heard)
        // Longest common subsequence table, then walk it back to mark the heard words that align.
        var table = Array(repeating: Array(repeating: 0, count: said.count + 1), count: words.count + 1)
        for i in stride(from: words.count - 1, through: 0, by: -1) {
            for j in stride(from: said.count - 1, through: 0, by: -1) {
                table[i][j] = words[i] == said[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var kept: [String] = []
        var i = 0, j = 0
        while i < words.count {
            if j < said.count, words[i] == said[j] {
                i += 1; j += 1
            } else if j < said.count, table[i][j + 1] >= table[i + 1][j] {
                j += 1
            } else {
                kept.append(words[i]); i += 1
            }
        }
        return kept.joined(separator: " ")
    }

    /// Normalised words, punctuation splitting them as speech does: "plan.txt" is heard as "plan txt".
    private static func words(of text: String) -> [String] {
        let spaced = String(text.unicodeScalars.map {
            CharacterSet.punctuationCharacters.contains($0) ? " " : Character($0)
        })
        return normaliseHeard(spaced).split(separator: " ").map(String.init)
    }
}
