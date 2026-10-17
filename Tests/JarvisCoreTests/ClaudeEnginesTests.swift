import Foundation
import Testing
@testable import JarvisCore

@Suite(.serialized) final class ClaudeEnginesTests {
    /// Every temp directory a test creates; removed when the suite instance goes away.
    private var claudeTestDirs: [URL] = []
    deinit { claudeTestDirs.forEach { try? FileManager.default.removeItem(at: $0) } }

    /// A fake `claude` in a fresh temp dir: records each argument on its own line in `args`, stdin in `stdin`,
    /// prints `stdout` and exits with `status`.
    private func claudeTestFake(stdout: String = "", status: Int32 = 0, extra: String = "") throws -> (ClaudeCLI, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "claude-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        claudeTestDirs.append(dir)
        try stdout.write(to: dir.appending(path: "out"), atomically: true, encoding: .utf8)
        let script = dir.appending(path: "claude")
        try """
        #!/bin/sh
        d="$(dirname "$0")"
        : > "$d/args"
        for a in "$@"; do printf '%s\\n' "$a" >> "$d/args"; done
        cat > "$d/stdin"
        \(extra)
        cat "$d/out"
        exit \(status)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (ClaudeCLI(executable: script), dir)
    }

    private func claudeTestArgs(_ dir: URL) throws -> [String] {
        try String(contentsOf: dir.appending(path: "args"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// The value that follows `flag`, `nil` if the flag is absent.
    private func claudeTestValue(_ flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    private static let claudeTestResult = #"{"type":"result","subtype":"success","is_error":false,"result":"Sent.","permission_denials":[]}"#

    // MARK: Command runner

    @Test func executePassesExactlyTheTickedToolsAndDraftPassesNone() async throws {
        let (cli, dir) = try claudeTestFake(stdout: Self.claudeTestResult)
        let runner = ClaudeCommandRunner(cli: cli, settings: { Settings(allowedTools: ["mcp__slack", "Read"]) })

        _ = try await runner.execute("Send Prashant the deck on Slack.")
        let exec = try claudeTestArgs(dir)
        #expect(exec.first == "-p")
        #expect(claudeTestValue("--allowedTools", in: exec) == "mcp__slack,Read")
        #expect(claudeTestValue("--tools", in: exec) == "Read")
        #expect(!exec.contains { $0.contains("Bash") || $0.contains("Edit") || $0.contains("Write") })

        _ = try await runner.draft("send Prashant the deck")
        let draft = try claudeTestArgs(dir)
        #expect(draft.first == "-p")
        #expect(claudeTestValue("--tools", in: draft) == "")
        #expect(draft.contains("--strict-mcp-config"))
        #expect(claudeTestValue("--permission-mode", in: draft) == "plan")
        #expect(!draft.contains("--allowedTools"))
    }

    @Test func executeWithNothingTickedPassesAnAllowListThatPermitsNothing() async throws {
        let (cli, dir) = try claudeTestFake(stdout: Self.claudeTestResult)
        let result = try await ClaudeCommandRunner(cli: cli, settings: { .default }).execute("Say hi.")

        let args = try claudeTestArgs(dir)
        #expect(result == "Sent.")
        #expect(claudeTestValue("--allowedTools", in: args) == "")
        #expect(claudeTestValue("--tools", in: args) == "")
        #expect(args.contains("--strict-mcp-config"))
        #expect(claudeTestValue("--permission-prompts", in: args) == "none")
        #expect(try String(contentsOf: dir.appending(path: "stdin"), encoding: .utf8) == "Say hi.")
    }

    @Test func aDeniedToolComesBackAsASentenceNamingIt() async throws {
        let denied = #"{"type":"result","is_error":false,"result":"I can't.","permission_denials":[{"tool_name":"mcp__slack__send_message","tool_use_id":"t1","tool_input":{}}]}"#
        let (cli, _) = try claudeTestFake(stdout: denied)
        let result = try await ClaudeCommandRunner(cli: cli, settings: { .default }).execute("Send it.")
        #expect(result == "I couldn't do that — slack send_message is not allowed in Settings.")
    }

    @Test func aFailingCLIDoesNotThrowIntoTheSession() async throws {
        let (cli, _) = try claudeTestFake(status: 3, extra: "echo boom >&2")
        let result = try await ClaudeCommandRunner(cli: cli, settings: { .default }).execute("Send it.")
        #expect(result == "I couldn't do that — Claude Code stopped with an error.")
        await #expect(throws: ClaudeError.exit(code: 3, stderr: "boom\n")) {
            try await cli.run(arguments: [], stdin: "", timeout: 10)
        }
    }

    // MARK: Note writer

    @Test func noteWriterSendsPromptAndTranscriptOnStdinWithNoTools() async throws {
        let (cli, dir) = try claudeTestFake(stdout: "## 10:00\n- Talked about the deck.\n")
        let note = try await ClaudeNoteWriter(cli: cli).note(from: "Me: the deck is ready", prompt: "Summarise.")

        let args = try claudeTestArgs(dir)
        #expect(note == "## 10:00\n- Talked about the deck.\n")
        #expect(args.first == "-p")
        #expect(claudeTestValue("--output-format", in: args) == "text")
        #expect(claudeTestValue("--tools", in: args) == "")
        #expect(args.contains("--strict-mcp-config"))
        #expect(!args.contains("--allowedTools"))
        #expect(try String(contentsOf: dir.appending(path: "stdin"), encoding: .utf8) == "Summarise.\n\nMe: the deck is ready")
    }

    // MARK: CLI

    @Test func locateFindsTheFirstExecutableClaudeInTheSearchedDirectories() throws {
        let (cli, dir) = try claudeTestFake()
        let empty = FileManager.default.temporaryDirectory.appending(path: "claude-empty-\(UUID().uuidString)")
        #expect(ClaudeCLI.locate(searching: [empty, dir]) == cli.executable)
        #expect(ClaudeCLI.locate(searching: [empty]) == nil)
    }

    @Test func runPastItsTimeoutTerminatesTheChild() async throws {
        let (cli, _) = try claudeTestFake(extra: "sleep 5")
        await #expect(throws: ClaudeError.timeout) {
            try await cli.run(arguments: [], stdin: "", timeout: 0.3)
        }
    }

    @Test func availableToolsListsBuiltInsThenEachMCPServer() async throws {
        let listing = """
        Checking MCP server health…

        claude.ai Claude Docs: https://api.anthropic.com/v1/pages/mcp - ✔ Connected
        plugin:design:google calendar:  (HTTP) - - Not configured
        slack: npx slack-mcp - ✔ Connected
        """
        let (cli, dir) = try claudeTestFake(stdout: listing)
        let tools = await cli.availableTools()

        #expect(try claudeTestArgs(dir) == ["mcp", "list"])
        #expect(tools.map(\.id) == ClaudeCLI.builtInTools
            + ["mcp__claude_ai_Claude_Docs", "mcp__plugin_design_google_calendar", "mcp__slack"])
        #expect(tools.first { $0.id == "Bash" }?.isShell == true)
        #expect(tools.filter(\.isFileEdit).map(\.id) == ToolIDs.fileEdits)
        #expect(tools.last == ToolDescriptor(id: "mcp__slack", title: "slack", isShell: false, isFileEdit: false))
    }

    // MARK: Smoke — the real `claude`. Costs money and needs auth, so off unless JARVIS_CLAUDE_SMOKE=1. No tool runs.

    private static var claudeTestSmoke: Bool {
        ProcessInfo.processInfo.environment["JARVIS_CLAUDE_SMOKE"] == "1" && ClaudeCLI.locate() != nil
    }

    @Test(.enabled(if: claudeTestSmoke, "set JARVIS_CLAUDE_SMOKE=1 with claude installed"))
    func smokeNoteWriterReturnsMarkdown() async throws {
        let cli = try #require(ClaudeCLI.locate().map(ClaudeCLI.init))
        let note = try await ClaudeNoteWriter(cli: cli)
            .note(from: "Me: let's ship the Jarvis demo on Friday.\nOthers: I'll book the room.",
                  prompt: "Write a short Markdown note with a heading and bullet points.")
        #expect(note.contains("#") || note.contains("- "))
    }

    @Test(.enabled(if: claudeTestSmoke, "set JARVIS_CLAUDE_SMOKE=1 with claude installed"))
    func smokeDraftReturnsOneSentenceWithoutActing() async throws {
        let cli = try #require(ClaudeCLI.locate().map(ClaudeCLI.init))
        let draft = try await ClaudeCommandRunner(cli: cli, settings: { .default })
            .draft("Create a file called jarvis-smoke.txt in my home folder saying hello.")
        #expect(!draft.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "jarvis-smoke.txt").path))
    }
}
