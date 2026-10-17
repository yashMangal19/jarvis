import Foundation

/// The transcript-text rule every engine's output goes through before it becomes a line.
enum TranscriptText {
    /// Removes bracketed placeholders (`[BLANK_AUDIO]`, `[INAUDIBLE]`, `[Music]`) and collapses
    /// whitespace. An empty result means the chunk held no speech.
    static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
