import Foundation

/// Where Homebrew's whisper.cpp binaries and the ggml models are.
public struct WhisperInstall {
    /// `whisper-server`: the long-lived default backend (D-5).
    public let server: URL?
    /// `whisper-cli` (older formulae: `whisper-cpp`): the fallback backend.
    public let cli: URL?

    /// `/opt/homebrew/bin`, `/usr/local/bin`, then `$PATH`.
    public static var defaultSearchPath: [URL] {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return (["/opt/homebrew/bin", "/usr/local/bin"] + path).map { URL(filePath: $0) }
    }

    public static func locate(searching directories: [URL] = defaultSearchPath) -> WhisperInstall {
        func first(_ names: [String]) -> URL? {
            for name in names {
                for directory in directories {
                    let candidate = directory.appending(path: name)
                    if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                }
            }
            return nil
        }
        return WhisperInstall(server: first(["whisper-server"]), cli: first(["whisper-cli", "whisper-cpp"]))
    }

    /// The main model: the largest present multilingual model, `nil` if none.
    public static func preferredModel(in models: URL) -> URL? {
        firstPresent(["ggml-large-v3-turbo.bin", "ggml-medium.bin", "ggml-small.bin"], in: models)
    }

    /// The wake-word model: the smallest present, `nil` if none.
    public static func wakeWordModel(in models: URL) -> URL? {
        firstPresent(["ggml-tiny.bin", "ggml-base.en.bin", "ggml-base.bin", "ggml-small.bin"], in: models)
    }

    private static func firstPresent(_ names: [String], in folder: URL) -> URL? {
        names.lazy.map { folder.appending(path: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
