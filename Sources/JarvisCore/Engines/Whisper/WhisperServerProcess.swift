import Darwin
import Foundation

/// A long-lived `whisper-server` child on 127.0.0.1 that loads its model once (D-5).
/// Relaunched on an unexpected exit, at most 3 times in 60 s; after that `failure` is set.
/// With a `pidFile`, a server left running by a previous Jarvis run (crash, SIGKILL) is terminated
/// at `start()` and its port reused, so orphaned servers do not pile up.
public final class WhisperServerProcess: @unchecked Sendable {
    /// Default ports: the main model and the wake-word model.
    public static let mainPort = 17_171
    public static let wakePort = 17_172

    public let binary: URL
    public let model: URL
    /// Holds `<pid> <start time> <port>` of the running child; removed by `stop()` only if this
    /// instance launched one, so discarding a never-started server leaves another run's record alone.
    public let pidFile: URL?
    private let lock = NSLock()
    private var requestedPort: Int
    private var process: Process?
    private var stopping = false
    private var launched = false
    private var budget = RestartBudget()
    private var _failure: Error?
    private let session: URLSession
    private let scheduler: any Scheduler

    public init(binary: URL, model: URL, port: Int, pidFile: URL? = nil, session: URLSession = .shared,
                scheduler: any Scheduler = SystemScheduler()) {
        self.scheduler = scheduler
        self.binary = binary
        self.model = model
        self.pidFile = pidFile
        self.requestedPort = port
        self.session = session
    }

    deinit { stop() }

    /// One pidfile per role (`"main"`, `"wake"`), in Jarvis's temp directory.
    public static func pidFile(role: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "jarvis-whisper-\(role).pid")
    }

    /// The port in use — the requested one, or the next free one if it was taken at `start()` or a relaunch.
    public var port: Int { lock.withLock { requestedPort } }
    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    /// Set when the server kept dying and relaunching stopped.
    public var failure: Error? { lock.withLock { _failure } }
    var pid: Int32? { lock.withLock { process.map(\.processIdentifier) } }

    /// Launches the server and returns once `/health` answers 200.
    public func start(timeout: TimeInterval = 120) async throws {
        let orphanPort = try await reapOrphan()
        try lock.withLock {
            stopping = false
            _failure = nil
            requestedPort = Self.freePort(from: orphanPort ?? requestedPort)
            try launch()
        }
        try await waitUntilReady(timeout: timeout)
    }

    /// Terminates the child and waits for it to exit, killing it if it ignores SIGTERM: returns within ~3 s.
    /// No relaunch follows.
    public func stop() {
        let (running, wrotePidFile): (Process?, Bool) = lock.withLock {
            stopping = true
            defer { process = nil; launched = false }
            return (process, launched)
        }
        if wrotePidFile, let pidFile { try? FileManager.default.removeItem(at: pidFile) }
        running?.terminateAndWait()
    }

    /// Polls `/health` until it answers 200 (whisper-server answers 503 while the model loads),
    /// the server keeps dying, or `timeout` passes.
    public func waitUntilReady(timeout: TimeInterval = 120) async throws {
        let deadline = scheduler.now + timeout
        while scheduler.now < deadline {
            if let failure { throw failure }
            var probe = URLRequest(url: baseURL.appending(path: "health"))
            probe.timeoutInterval = 1
            if ((try? await session.data(for: probe))?.1 as? HTTPURLResponse)?.statusCode == 200 { return }
            try await scheduler.sleep(for: 0.2)
        }
        throw WhisperError.serverNotReady
    }

    // Must hold `lock`. Flags confirmed with `whisper-server --help` (whisper.cpp 1.9.5).
    private func launch() throws {
        let child = Process()
        child.executableURL = binary
        child.arguments = ["--host", "127.0.0.1", "--port", String(requestedPort), "-m", model.path]
        // The server logs per request; an unread pipe would eventually block it.
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] exited in self?.exited(exited) }
        try child.run()
        process = child
        launched = true
        if let pidFile, let started = Self.startTime(of: child.processIdentifier) {
            try? "\(child.processIdentifier) \(started) \(requestedPort)".write(to: pidFile, atomically: true, encoding: .utf8)
        }
    }

    /// Terminates the server the pidfile records, if that exact process still runs, and returns its port.
    /// Identity is pid plus start time, so a recycled pid now owned by another process is never signalled.
    private func reapOrphan() async throws -> Int? {
        guard let pidFile, let fields = try? String(contentsOf: pidFile, encoding: .utf8).split(separator: " "),
              fields.count == 3, let pid = Int32(fields[0]), let started = UInt64(fields[1]), let port = Int(fields[2])
        else { return nil }
        try? FileManager.default.removeItem(at: pidFile)
        guard Self.startTime(of: pid) == started else { return nil }
        kill(pid, SIGTERM)
        for _ in 0..<100 where Self.startTime(of: pid) == started { try await scheduler.sleep(for: 0.05) }
        if Self.startTime(of: pid) == started { kill(pid, SIGKILL) }
        return port
    }

    /// When `pid` started, in microseconds since 1970; `nil` if no such process.
    static func startTime(of pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    private func exited(_ child: Process) {
        lock.withLock {
            guard !stopping, child === process else { return }
            process = nil
            guard budget.allow(at: Date()) else { _failure = WhisperError.serverKeepsExiting; return }
            // The port may have been taken since `start()` (e.g. by the other role's server).
            requestedPort = Self.freePort(from: requestedPort)
            do { try launch() } catch { _failure = error }
        }
    }

    /// `port` if nothing listens on 127.0.0.1:`port`, else the next port that binds.
    static func freePort(from port: Int) -> Int {
        (port..<port + 100).first(where: canBind) ?? port
    }

    private static func canBind(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // As the server binds: a port left in TIME_WAIT by a previous run is free; a live listener is not.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

/// At most `limit` relaunches inside any `window`-second span.
struct RestartBudget {
    let limit = 3
    let window: TimeInterval = 60
    private var recent: [Date] = []

    mutating func allow(at now: Date) -> Bool {
        recent.removeAll { now.timeIntervalSince($0) >= window }
        guard recent.count < limit else { return false }
        recent.append(now)
        return true
    }
}
