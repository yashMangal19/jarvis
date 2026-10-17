import Foundation

/// One child process run to completion: both output pipes drained, optional stdin, optional timeout.
///
/// `Process` makes the child a process-group leader and `terminate()` signals that whole group (checked on this Mac
/// with a backgrounded grandchild), so a timeout or cancel also stops what the child started. A grandchild that
/// leaves the group (`setsid`, a detached spawn) is out of reach.
enum ChildProcess {
    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: Data
        /// Killed by the timeout rather than exiting on its own.
        let timedOut: Bool
    }

    /// Throws `CancellationError` if the task is cancelled (the child is terminated). When `stdin` is given and the
    /// child exits 0 without reading all of it, the write error is thrown; a non-zero exit is returned as is, since
    /// its stderr says more than a closed pipe does.
    static func run(_ executable: URL, arguments: [String], stdin: Data? = nil, directory: URL? = nil,
                    timeout: TimeInterval? = nil) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let input = Pipe(), stdout = Pipe(), stderr = Pipe()
        if stdin != nil {
            // A write to a child that has exited would otherwise raise SIGPIPE and kill the app.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.standardInput = input
        }
        process.standardOutput = stdout
        process.standardError = stderr
        // Awaited rather than `waitUntilExit()`, which blocks a cooperative thread.
        let (exit, exited) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { exited.yield($0.terminationStatus); exited.finish() }
        try process.run()
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        let timer = timeout.map { timeout in
            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                DispatchQueue.global().async { process.terminateAndWait() }
            }
        }
        defer { timer?.cancel() }
        // Cancelling terminates (then kills) the child, which closes its pipes and ends the reads below.
        return try await withTaskCancellationHandler {
            // Written off-thread and closed, so a child that reads slowly cannot block us and sees EOF.
            async let written: Error? = Task.detached {
                guard let stdin else { return nil }
                defer { try? input.fileHandleForWriting.close() }
                do { try input.fileHandleForWriting.write(contentsOf: stdin); return nil } catch { return error }
            }.value
            // Both pipes are drained concurrently so a chatty stderr cannot block the child.
            async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
            async let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
            let (outData, errData, writeError) = await (out, err, written)
            var status: Int32 = -1
            for await code in exit { status = code }
            try Task.checkCancellation()
            let timedOut = process.terminationReason == .uncaughtSignal && deadline.map { Date() >= $0 } == true
            if let writeError, status == 0, !timedOut { throw writeError }
            return Output(status: status, stdout: outData, stderr: errData, timedOut: timedOut)
        } onCancel: {
            DispatchQueue.global().async { process.terminateAndWait() }
        }
    }
}

extension Process {
    /// SIGTERM (to the child's process group, as `terminate()` does), then SIGKILL to the group if it is still
    /// running `grace` seconds later. Returns once it has exited, or 1 s after the SIGKILL: never blocks longer.
    ///
    /// Polls `isRunning` rather than calling `waitUntilExit()`, which, called off the main thread, can miss the
    /// exit and block forever (reproduced on macOS 27: child gone, `isRunning` false, still waiting).
    func terminateAndWait(grace: TimeInterval = 2) {
        func exited(within seconds: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while isRunning, Date() < deadline { usleep(10_000) }
            return !isRunning
        }
        guard isRunning else { return }
        terminate()
        if exited(within: grace) { return }
        if killpg(processIdentifier, SIGKILL) != 0 { kill(processIdentifier, SIGKILL) }
        _ = exited(within: 1)
    }
}
