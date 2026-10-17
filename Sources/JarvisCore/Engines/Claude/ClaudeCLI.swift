import Foundation

public enum ClaudeError: Error, Equatable {
    case exit(code: Int32, stderr: String)
    case timeout
}

/// One row of the Settings "Allowed tools" checklist: a built-in Claude Code tool or a whole MCP server.
public struct ToolDescriptor: Equatable {
    /// What goes into `--allowedTools`: `Bash`, or `mcp__<server>` for every tool of that server.
    public let id: String
    public let title: String
    public let isShell: Bool
    public let isFileEdit: Bool
}

/// The Claude Code command-line tool, run as a child process.
public struct ClaudeCLI {
    /// A curated subset of the built-in tools `--tools` accepts — the ones a spoken command plausibly needs. Others
    /// (TodoWrite, Skill, the Bash output/kill tools, …) are left out on purpose and so can never be ticked. Anything
    /// else in an allow list is an MCP server.
    public static let builtInTools = ["Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "Read", "Glob", "Grep",
                                      "WebFetch", "WebSearch", "Task"]

    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// Homebrew dirs and `$PATH`, then the native (`~/.local/bin`) and legacy (`~/.claude/local`) installers' homes —
    /// an app opened from Finder gets a short `$PATH` that has neither.
    public static var defaultSearchPath: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return WhisperInstall.defaultSearchPath + [home.appending(path: ".local/bin"), home.appending(path: ".claude/local")]
    }

    public static func locate(searching directories: [URL] = defaultSearchPath) -> URL? {
        directories.lazy.map { $0.appending(path: "claude") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// On every `-p` run: no user, project or local settings file (so no allow rules, default mode or hooks of the
    /// user's), and a permission mode that denies whatever is not explicitly allowed.
    static let pinned = ["--setting-sources", "", "--permission-mode", "dontAsk"]

    /// Every `claude` run starts here: an empty folder Jarvis owns, so no `.claude/` settings, `CLAUDE.md` or
    /// `.mcp.json` from wherever the app was launched (`/` from Finder) is picked up, and relative paths land nowhere.
    static let workingDirectory = FileManager.default.temporaryDirectory.appending(path: "jarvis-claude")

    /// Runs `claude` with `stdin` piped in; stdout on exit 0, else `ClaudeError.exit`. Past `timeout` the child (and
    /// its process group) is terminated and `ClaudeError.timeout` thrown.
    public func run(arguments: [String], stdin: String, timeout: TimeInterval) async throws -> String {
        try FileManager.default.createDirectory(at: Self.workingDirectory, withIntermediateDirectories: true)
        let output = try await ChildProcess.run(executable, arguments: arguments, stdin: Data(stdin.utf8),
                                                directory: Self.workingDirectory, timeout: timeout)
        if output.timedOut { throw ClaudeError.timeout }
        guard output.status == 0 else {
            throw ClaudeError.exit(code: output.status, stderr: String(decoding: output.stderr, as: UTF8.self))
        }
        return String(decoding: output.stdout, as: UTF8.self)
    }

    /// The built-in tools, then one entry per MCP server from `claude mcp list` (it lists servers, not their
    /// tools, so a server is ticked as a whole). A failing `mcp list` leaves the built-ins only.
    public func availableTools() async -> [ToolDescriptor] {
        let builtIns = Self.builtInTools.map {
            ToolDescriptor(id: $0, title: $0, isShell: ToolIDs.shell.contains($0), isFileEdit: ToolIDs.fileEdits.contains($0))
        }
        guard let listing = try? await mcpListing() else { return builtIns }
        return builtIns + Self.mcpServers(in: listing).map {
            ToolDescriptor(id: "mcp__\(Self.toolSegment($0))", title: $0, isShell: false, isFileEdit: false)
        }
    }

    /// `mcp__<server>` for every MCP server `claude mcp list` shows.
    func mcpServerIDs() async throws -> [String] {
        Self.mcpServers(in: try await mcpListing()).map { "mcp__\(Self.toolSegment($0))" }
    }

    private func mcpListing() async throws -> String {
        try await run(arguments: ["mcp", "list"], stdin: "", timeout: 60)
    }

    /// Server names from `mcp list` lines shaped `<name>: <url or command> - <status>`. A name may hold `:` and
    /// spaces (`plugin:design:google calendar`) but never `": "`, so it ends at the first one.
    static func mcpServers(in listing: String) -> [String] {
        listing.split(separator: "\n").compactMap { line in
            guard line.contains(" - "), let colon = line.range(of: ": ") else { return nil }
            return String(line[..<colon.lowerBound])
        }
    }

    /// The server's segment in an `mcp__<server>__<tool>` id, normalised the way Claude Code 2.1.302 does it:
    /// anything outside `[A-Za-z0-9_-]` becomes `_`; `claude.ai ` connectors also collapse and trim `_`.
    static func toolSegment(_ server: String) -> String {
        var segment = server.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        if server.hasPrefix("claude.ai ") {
            segment = segment.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        }
        return segment
    }
}
