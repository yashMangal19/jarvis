import Foundation

/// Turns one chunk of audio into text.
public protocol Transcriber {
    func transcribe(_ chunk: AudioChunk) async throws -> String
}

/// Turns a transcript into a note, guided by a prompt.
public protocol NoteWriter {
    func note(from transcript: String, prompt: String) async throws -> String
}

/// Turns text into a vector for similarity search.
public protocol Embedder {
    func embed(_ text: String) throws -> [Float]
}

/// Runs a spoken command in two phases.
public protocol CommandRunner {
    /// Implementations must not act in `draft`; it only returns the plan — a
    /// one-sentence description of what *would* be done. No tool is called.
    func draft(_ command: String) async throws -> String

    /// Callers must invoke `execute` only after the user has explicitly
    /// confirmed the draft — never on a timeout or a "no". `CommandSession`
    /// is the gate that enforces this.
    func execute(_ draft: String) async throws -> String
}
