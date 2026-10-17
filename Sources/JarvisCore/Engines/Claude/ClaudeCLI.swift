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
    /// Ids accepted by `--tools` (the built-in set); anything else in an allow list is an MCP tool.
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

    /// Runs `claude` with `stdin` piped in; stdout on exit 0, else `ClaudeError.exit`. Past `timeout` the child is
    /// terminated and `ClaudeError.timeout` thrown.
    public func run(arguments: [String], stdin: String, timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let input = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = stderr
        // Awaited rather than `waitUntilExit()`, which blocks a cooperative thread.
        let (exit, exited) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { exited.yield($0.terminationStatus); exited.finish() }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            process.terminate()
        }
        defer { timer.cancel() }
        // Cancelling terminates the child, which closes its pipes and ends the reads below.
        return try await withTaskCancellationHandler {
            // Written off-thread and closed, so a child that reads slowly cannot block us and sees EOF.
            Task.detached {
                try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            }
            // Both pipes are drained concurrently so a chatty stderr cannot block the child.
            async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
            async let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
            let (outData, errData) = await (out, err)
            var status: Int32 = -1
            for await code in exit { status = code }
            try Task.checkCancellation()
            if process.terminationReason == .uncaughtSignal, Date() >= deadline { throw ClaudeError.timeout }
            guard status == 0 else {
                throw ClaudeError.exit(code: status, stderr: String(decoding: errData, as: UTF8.self))
            }
            return String(decoding: outData, as: UTF8.self)
        } onCancel: {
            process.terminate()
        }
    }

    /// The built-in tools, then one entry per MCP server from `claude mcp list` (it lists servers, not their
    /// tools, so a server is ticked as a whole). A failing `mcp list` leaves the built-ins only.
    public func availableTools() async -> [ToolDescriptor] {
        let builtIns = Self.builtInTools.map {
            ToolDescriptor(id: $0, title: $0, isShell: ToolIDs.shell.contains($0), isFileEdit: ToolIDs.fileEdits.contains($0))
        }
        guard let listing = try? await run(arguments: ["mcp", "list"], stdin: "", timeout: 60) else { return builtIns }
        return builtIns + Self.mcpServers(in: listing).map {
            ToolDescriptor(id: "mcp__\(Self.toolSegment($0))", title: $0, isShell: false, isFileEdit: false)
        }
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
