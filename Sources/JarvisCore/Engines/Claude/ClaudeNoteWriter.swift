import Foundation

/// Writes notes with `claude -p`: prompt and transcript on stdin, no tools, nothing kept in Claude's session history.
public struct ClaudeNoteWriter: NoteWriter {
    private let cli: ClaudeCLI

    public init(cli: ClaudeCLI) {
        self.cli = cli
    }

    public var displayName: String { "Claude" }

    public func note(from transcript: String, prompt: String) async throws -> String {
        try await cli.run(arguments: ["-p", "--output-format", "text", "--tools", "", "--strict-mcp-config",
                                      "--no-session-persistence"],
                          stdin: "\(prompt)\n\n\(transcript)", timeout: 120)
    }
}
