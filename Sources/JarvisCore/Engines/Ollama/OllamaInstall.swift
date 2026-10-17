import Foundation

/// Whether Ollama can be used on this Mac. The two answers are separate so the menu can say
/// "start Ollama" when it is installed but not running.
public enum OllamaInstall {
    public static let defaultURL = URL(string: "http://127.0.0.1:11434")!

    /// The server answers `GET /api/tags` with 200. The request uses a 2-second
    /// `timeoutInterval`, which is an idle timeout (no bytes for 2 s), not a total deadline.
    public static func isAvailable(baseURL: URL = defaultURL, session: URLSession = .shared) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        let response = try? await session.data(for: request).1
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// An executable `ollama` exists in one of `directories` — the same search path whisper.cpp uses.
    public static func isInstalled(searching directories: [URL] = WhisperInstall.defaultSearchPath) -> Bool {
        directories.contains { FileManager.default.isExecutableFile(atPath: $0.appending(path: "ollama").path) }
    }
}
