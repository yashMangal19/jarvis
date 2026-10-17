#if canImport(FoundationModels)
import FoundationModels

/// Writes notes on-device with Apple's system language model (macOS 26+, Apple Intelligence on).
@available(macOS 26, *)
public struct FoundationModelsNoteWriter: NoteWriter {
    public let displayName = "Apple Foundation Models"

    private let maxCharacters: Int

    /// `maxCharacters` is the transcript size sent in one call; longer transcripts are chunked.
    /// Default: half the model's context, at ~3 characters per token.
    /// Ceiling: a character estimate, not a token count; `SystemLanguageModel.tokenCount(for:)`
    /// (macOS 26.4+) is the upgrade if chunks ever overflow.
    public init(maxCharacters: Int = SystemLanguageModel.default.contextSize * 3 / 2) {
        self.maxCharacters = maxCharacters
    }

    public static func isAvailable() -> Bool {
        SystemLanguageModel.default.availability == .available
    }

    public func note(from transcript: String, prompt: String) async throws -> String {
        guard transcript.count > maxCharacters else {
            return try await respond(prompt: prompt, to: transcript)
        }
        var partials: [String] = []
        for chunk in TranscriptChunker.chunks(transcript, maxCharacters: maxCharacters) {
            partials.append(try await respond(prompt: prompt, to: chunk))
        }
        // One merge call. Ceiling: assumes the partial notes together fit the context.
        return try await respond(prompt: prompt, to: partials.joined(separator: "\n\n"))
    }

    /// A fresh session per call, so earlier chunks do not fill the context.
    private func respond(prompt: String, to text: String) async throws -> String {
        try await LanguageModelSession(instructions: prompt).respond(to: text).content
    }
}
#endif
