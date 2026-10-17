import Darwin
import Foundation

/// A long-lived `whisper-server` child on 127.0.0.1 that loads its model once (D-5).
/// Relaunched on an unexpected exit, at most 3 times in 60 s; after that `failure` is set.
public final class WhisperServerProcess: @unchecked Sendable {
    /// Default ports: the main model and the wake-word model.
    public static let mainPort = 17_171
    public static let wakePort = 17_172

    public let binary: URL
    public let model: URL
    private let lock = NSLock()
    private var requestedPort: Int
    private var process: Process?
    private var stopping = false
    private var budget = RestartBudget()
    private var _failure: Error?

    public init(binary: URL, model: URL, port: Int) {
        self.binary = binary
        self.model = model
        self.requestedPort = port
    }

    deinit { stop() }

    /// The port in use — the requested one, or the next free one if it was taken at `start()`.
    public var port: Int { lock.withLock { requestedPort } }
    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    /// Set when the server kept dying and relaunching stopped.
    public var failure: Error? { lock.withLock { _failure } }
    var pid: Int32? { lock.withLock { process.map(\.processIdentifier) } }

    /// Launches the server and returns once it answers HTTP.
    public func start(timeout: TimeInterval = 120) async throws {
        try lock.withLock {
            stopping = false
            _failure = nil
            requestedPort = Self.freePort(from: requestedPort)
            try launch()
        }
        try await waitUntilReady(timeout: timeout)
    }

    /// Terminates the child and waits for it to exit. No relaunch follows.
    public func stop() {
        let running: Process? = lock.withLock {
            stopping = true
            defer { process = nil }
            return process
        }
        guard let running, running.isRunning else { return }
        running.terminate()
        running.waitUntilExit()
    }

    /// Polls `/` until the server answers (model loaded), the child dies, or `timeout` passes.
    public func waitUntilReady(timeout: TimeInterval = 120) async throws {
        let deadline = Date() + timeout
        while Date() < deadline {
            if let failure { throw failure }
            var probe = URLRequest(url: baseURL)
            probe.timeoutInterval = 1
            if (try? await URLSession.shared.data(for: probe))?.1 is HTTPURLResponse { return }
            try await Task.sleep(nanoseconds: 200_000_000)
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
    }

    private func exited(_ child: Process) {
        lock.withLock {
            guard !stopping, child === process else { return }
            process = nil
            guard budget.allow(at: Date()) else { _failure = WhisperError.serverKeepsExiting; return }
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
