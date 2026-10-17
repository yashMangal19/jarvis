import Foundation

/// Spoken commands through `claude -p`, in the two phases `CommandRunner` describes.
///
/// `draft` cannot act: every built-in tool is removed (`--tools ""`), no MCP server is loaded
/// (`--strict-mcp-config` with no `--mcp-config`), and it runs in plan mode.
/// `execute` gets only the tools ticked in Settings: built-ins outside the ticked list are removed with `--tools`,
/// and with `--permission-prompts none` anything not on `--allowedTools` is denied rather than asked about.
/// Like the protocol, nothing here stops a caller running `execute` without a yes.
public struct ClaudeCommandRunner: CommandRunner {
    private let cli: ClaudeCLI
    private let settings: () -> Settings

    static let draftInstruction = "Reply with exactly one sentence that states what you would do, to whom, and with "
        + "what exact content, and nothing else. Never act: do not call any tool."

    public init(cli: ClaudeCLI, settings: @escaping () -> Settings) {
        self.cli = cli
        self.settings = settings
    }

    public func draft(_ command: String) async throws -> String {
        let plan = try await cli.run(arguments: ["-p", "--output-format", "text", "--tools", "", "--strict-mcp-config",
                                                 "--permission-mode", "plan", "--no-session-persistence",
                                                 "--append-system-prompt", Self.draftInstruction],
                                     stdin: command, timeout: 120)
        return plan.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Never throws a tool or CLI failure into the session: it comes back as a sentence to speak.
    public func execute(_ draft: String) async throws -> String {
        let ticked = settings().allowedTools
        let builtIns = ticked.filter(ClaudeCLI.builtInTools.contains)
        var arguments = ["-p", "--output-format", "json", "--permission-prompts", "none", "--no-session-persistence",
                         "--tools", builtIns.joined(separator: ","), "--allowedTools", ticked.joined(separator: ",")]
        if builtIns.count == ticked.count { arguments.append("--strict-mcp-config") }
        let output: String
        do {
            // The draft goes on stdin, not as the positional prompt, so a draft starting with "-" is not read as a flag.
            output = try await cli.run(arguments: arguments, stdin: draft, timeout: 180)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Self.failed
        }
        guard let result = try? JSONDecoder().decode(Result.self, from: Data(output.utf8)) else { return Self.failed }
        if let denied = result.permission_denials?.first {
            return "I couldn't do that — \(Self.spoken(denied.tool_name)) is not allowed in Settings."
        }
        guard result.is_error != true, let text = result.result else { return Self.failed }
        return text
    }

    static let failed = "I couldn't do that — Claude Code stopped with an error."

    /// `mcp__slack__send_message` → `slack send_message`, so a denial reads aloud as words.
    private static func spoken(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        return tool.dropFirst(5).replacingOccurrences(of: "__", with: " ")
    }

    /// The `--output-format json` result fields read here (confirmed in the Claude Code 2.1.302 binary's schema).
    private struct Result: Decodable {
        struct Denial: Decodable { let tool_name: String }
        let result: String?
        let is_error: Bool?
        let permission_denials: [Denial]?
    }
}
