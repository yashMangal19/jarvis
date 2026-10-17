import Foundation

/// Whether Ollama can be used on this Mac. The two answers are separate so the menu can say
/// "start Ollama" when it is installed but not running.
public enum OllamaInstall {
    public static let defaultURL = URL(string: "http://127.0.0.1:11434")!

    /// A launched app's PATH omits Homebrew, so its two prefixes are always searched.
    public static let defaultSearchPaths: [String] =
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        + ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The server answers `GET /api/tags` with 200 within 2 seconds.
    public static func isAvailable(baseURL: URL = defaultURL, session: URLSession = .shared) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        let response = try? await session.data(for: request).1
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// An executable `ollama` exists in one of `directories`.
    public static func isInstalled(searching directories: [String] = defaultSearchPaths) -> Bool {
        directories.contains { FileManager.default.isExecutableFile(atPath: "\($0)/ollama") }
    }
}
