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
    /// Invariant: `draft` never acts. It only returns a one-sentence plan of
    /// what *would* be done; no tool is called and nothing changes.
    func draft(_ command: String) async throws -> String

    /// Invariant: `execute` runs only after the user has explicitly said yes
    /// to the draft. Callers must never invoke it on a timeout or a "no".
    func execute(_ draft: String) async throws -> String
}
