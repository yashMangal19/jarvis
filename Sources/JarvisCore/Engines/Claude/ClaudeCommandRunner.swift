import Foundation

/// Spoken commands through `claude -p`, in the two phases `CommandRunner` describes.
///
/// Every run is pinned so the user's own Claude Code configuration cannot widen it (flags as listed by
/// `claude --help`, 2.1.302): `--setting-sources ""` loads no user, project or local settings file, so none of their
/// `permissions.allow` rules, `defaultMode` or hooks apply; `--permission-mode dontAsk` denies anything not already
/// allowed; and `ClaudeCLI` starts it in an empty Jarvis-owned folder, so no project `.claude/` or `.mcp.json` applies.
///
/// `draft` cannot act: every built-in tool is removed (`--tools ""`) and no MCP server is loaded
/// (`--strict-mcp-config` with no `--mcp-config`).
/// `execute` can run only the tools ticked in Settings: built-ins outside the ticked list are removed with `--tools`,
/// the only allow rules are `--allowedTools`, and with `--permission-prompts none` anything else is denied rather
/// than asked about. With no MCP server ticked none is loaded; with one ticked every server is loaded (a claude.ai
/// connector cannot be passed through `--mcp-config`), so each unticked server `claude mcp list` shows is also put
/// on `--disallowedTools`, and if that list cannot be read the command is refused.
///
/// Not enforced here: managed (admin policy) settings still apply and could allow more; a server `mcp list` did not
/// show is denied by `dontAsk` alone. Like the protocol, nothing here stops a caller running `execute` without a yes.
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
        let plan = try await cli.run(arguments: ["-p", "--output-format", "text"] + ClaudeCLI.pinned
                                         + ["--tools", "", "--strict-mcp-config", "--no-session-persistence",
                                            "--append-system-prompt", Self.draftInstruction],
                                     stdin: command, timeout: 120)
        return plan.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Never throws a tool or CLI failure into the session: it comes back as a sentence to speak.
    public func execute(_ draft: String) async throws -> String {
        let ticked = settings().allowedTools
        let builtIns = ticked.filter(ClaudeCLI.builtInTools.contains)
        var arguments = ["-p", "--output-format", "json", "--permission-prompts", "none", "--no-session-persistence"]
            + ClaudeCLI.pinned
        let output: String
        do {
            if builtIns.count == ticked.count {
                arguments.append("--strict-mcp-config")
            } else {
                let unticked = try await cli.mcpServerIDs().filter { !ticked.contains($0) }
                if !unticked.isEmpty { arguments += ["--disallowedTools", unticked.joined(separator: ",")] }
            }
            arguments += ["--tools", builtIns.joined(separator: ","), "--allowedTools", ticked.joined(separator: ",")]
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

    /// A failed run names no tool, so it cannot say which one Settings refused (the blueprint's wording); it says
    /// that Claude Code failed instead.
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
