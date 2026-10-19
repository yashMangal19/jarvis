import Foundation
import Testing
@testable import JarvisCore

@Suite(.serialized) final class ClaudeEnginesTests {
    /// Every temp directory a test creates; removed when the suite instance goes away.
    private var claudeTestDirs: [URL] = []
    deinit { claudeTestDirs.forEach { try? FileManager.default.removeItem(at: $0) } }

    /// A fake `claude` in a fresh temp dir: records each argument on its own line in `args`, its working directory in
    /// `pwd`, stdin in `stdin`, prints `stdout` and exits with `status`. `before` runs ahead of reading stdin.
    private func claudeTestFake(stdout: String = "", status: Int32 = 0, before: String = "",
                                extra: String = "", scheduler: any Scheduler = SystemScheduler()) throws -> (ClaudeCLI, URL) {
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
        pwd -P > "$d/pwd"
        \(before)
        cat > "$d/stdin"
        \(extra)
        cat "$d/out"
        exit \(status)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (ClaudeCLI(executable: script, scheduler: scheduler), dir)
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
        #expect(claudeTestValue("--permission-mode", in: draft) == "dontAsk")
        #expect(claudeTestValue("--setting-sources", in: draft) == "")
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
        #expect(claudeTestValue("--permission-mode", in: args) == "dontAsk")
        #expect(claudeTestValue("--setting-sources", in: args) == "")
        #expect(!args.contains("--disallowedTools"))
        #expect(try String(contentsOf: dir.appending(path: "stdin"), encoding: .utf8) == "Say hi.")
    }

    @Test func executeWithOneMCPServerTickedDeniesEveryOtherServerAndIgnoresTheUsersSettings() async throws {
        // `mcp list` (run first) shows two servers; the execute call that follows overwrites `args`.
        let (cli, dir) = try claudeTestFake(stdout: Self.claudeTestResult, extra: """
        [ "$1" = mcp ] && { printf '%s\\n' 'slack: npx slack-mcp - ✔ Connected' 'gmail: npx gmail-mcp - ✔ Connected'; exit 0; }
        """)
        let runner = ClaudeCommandRunner(cli: cli, settings: { Settings(allowedTools: ["mcp__slack", "Read"]) })

        #expect(try await runner.execute("Send Prashant the deck on Slack.") == "Sent.")
        let args = try claudeTestArgs(dir)
        #expect(args.first == "-p")
        #expect(claudeTestValue("--allowedTools", in: args) == "mcp__slack,Read")
        #expect(claudeTestValue("--disallowedTools", in: args) == "mcp__gmail")
        #expect(claudeTestValue("--permission-mode", in: args) == "dontAsk")
        #expect(claudeTestValue("--permission-prompts", in: args) == "none")
        #expect(claudeTestValue("--setting-sources", in: args) == "")
    }

    @Test func executeFailsClosedWhenTheMCPServersCannotBeListed() async throws {
        let (cli, dir) = try claudeTestFake(stdout: Self.claudeTestResult, extra: #"[ "$1" = mcp ] && exit 1"#)
        let runner = ClaudeCommandRunner(cli: cli, settings: { Settings(allowedTools: ["mcp__slack"]) })

        #expect(try await runner.execute("Send it.") == ClaudeCommandRunner.failed)
        #expect(try claudeTestArgs(dir) == ["mcp", "list"])
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
        #expect(claudeTestValue("--permission-mode", in: args) == "dontAsk")
        #expect(claudeTestValue("--setting-sources", in: args) == "")
        #expect(try String(contentsOf: dir.appending(path: "stdin"), encoding: .utf8) == "Summarise.\n\nMe: the deck is ready")
    }

    // MARK: CLI

    @Test func locateFindsTheFirstExecutableClaudeInTheSearchedDirectories() throws {
        let (cli, dir) = try claudeTestFake()
        let empty = FileManager.default.temporaryDirectory.appending(path: "claude-empty-\(UUID().uuidString)")
        #expect(ClaudeCLI.locate(searching: [empty, dir]) == cli.executable)
        #expect(ClaudeCLI.locate(searching: [empty]) == nil)
    }

    @Test func runIsPinnedToAnEmptyJarvisOwnedDirectory() async throws {
        let (cli, dir) = try claudeTestFake()
        _ = try await cli.run(arguments: [], stdin: "", timeout: 10)
        let pwd = try String(contentsOf: dir.appending(path: "pwd"), encoding: .utf8)
        let jarvisOwned = FileManager.default.temporaryDirectory.appending(path: "jarvis-claude").path
        #expect(pwd == realpath(jarvisOwned, nil).map { String(cString: $0) }.map { $0 + "\n" })
    }

    @Test func aChildThatExitsWithoutReadingALargeStdinThrowsInsteadOfKillingTheApp() async throws {
        let big = String(repeating: "transcript line\n", count: 64 * 1024)  // 1 MB, far past the pipe buffer
        let (quits, _) = try claudeTestFake(before: "exit 0")
        await #expect(throws: (any Error).self) { try await quits.run(arguments: [], stdin: big, timeout: 10) }
        let (fails, _) = try claudeTestFake(status: 3, before: "echo nope >&2; exit 3")
        await #expect(throws: ClaudeError.exit(code: 3, stderr: "nope\n")) {
            try await fails.run(arguments: [], stdin: big, timeout: 10)
        }
    }

    /// The timeout fires on virtual time, after the child has started its own child (J-022): how fast the
    /// script starts no longer decides what is tested.
    @Test func aTimeoutAlsoTerminatesWhatTheChildStarted() async throws {
        let clock = VirtualScheduler()
        let (cli, dir) = try claudeTestFake(extra: #"sleep 30 >/dev/null 2>&1 </dev/null & echo $! > "$d/child"; wait"#,
                                            scheduler: clock)
        let run = Task { try await cli.run(arguments: [], stdin: "", timeout: 0.5) }
        let childFile = dir.appending(path: "child")
        for _ in 0..<500 where (try? String(contentsOf: childFile, encoding: .utf8))?.hasSuffix("\n") != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await clock.waitForPending())
        clock.advance(by: 0.5)
        await #expect(throws: ClaudeError.timeout) { try await run.value }
        let child = try #require(Int32(String(contentsOf: childFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        var alive = true
        for _ in 0..<20 where alive {
            try await Task.sleep(nanoseconds: 50_000_000)
            alive = kill(child, 0) == 0
        }
        if alive { kill(child, SIGKILL) }
        #expect(!alive)
    }

    @Test func runPastItsTimeoutTerminatesTheChild() async throws {
        let (cli, _) = try claudeTestFake(extra: "sleep 5")
        await #expect(throws: ClaudeError.timeout) {
            try await cli.run(arguments: [], stdin: "", timeout: 0.3)
        }
    }

    // T-26 F-3, DEC-9: a ticked id that Claude Code no longer lists stays visible, so it can be unticked.
    @Test func checklistAddsTickedToolsNoLongerListedAsUnlistedRows() {
        let read = ToolDescriptor(id: "Read", title: "Read", isShell: false, isFileEdit: false)
        let calendar = ToolDescriptor(id: "mcp__calendar", title: "calendar", isShell: false, isFileEdit: false)

        let rows = ToolDescriptor.checklist(available: [read, calendar],
                                            allowed: ["mcp__calendar", "mcp__gone", "Bash", "Read"])

        #expect(rows.map(\.id) == ["Read", "mcp__calendar", "mcp__gone", "Bash"])
        #expect(rows.map(\.isUnlisted) == [false, false, true, true])
        #expect(rows[3].isShell)
        #expect(ToolDescriptor.checklist(available: [read], allowed: []) == [read])
    }

    // With no Claude Code nothing is listed, and every ticked id is still shown.
    @Test func checklistWithNothingListedShowsEveryTickedTool() {
        let rows = ToolDescriptor.checklist(available: [], allowed: ["Edit", "mcp__notes"])

        #expect(rows.map(\.id) == ["Edit", "mcp__notes"])
        #expect(rows.allSatisfy { $0.isUnlisted })
        #expect(rows[0].isFileEdit)
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
        let cli = try #require(ClaudeCLI.locate().map { ClaudeCLI(executable: $0) })
        let note = try await ClaudeNoteWriter(cli: cli)
            .note(from: "Me: let's ship the Jarvis demo on Friday.\nOthers: I'll book the room.",
                  prompt: "Write a short Markdown note with a heading and bullet points.")
        #expect(note.contains("#") || note.contains("- "))
    }

    @Test(.enabled(if: claudeTestSmoke, "set JARVIS_CLAUDE_SMOKE=1 with claude installed"))
    func smokeDraftReturnsOneSentenceWithoutActing() async throws {
        let cli = try #require(ClaudeCLI.locate().map { ClaudeCLI(executable: $0) })
        let draft = try await ClaudeCommandRunner(cli: cli, settings: { .default })
            .draft("Create a file called jarvis-smoke.txt in my home folder saying hello.")
        #expect(!draft.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "jarvis-smoke.txt").path))
    }
}
