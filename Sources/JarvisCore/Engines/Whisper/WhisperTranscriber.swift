import Foundation

public enum WhisperError: Error, Equatable {
    case audioConversion
    case cliFailed(status: Int32, stderr: String)
    case serverFailed(status: Int, body: String)
    case serverNotReady
    case serverKeepsExiting
    case downloadFailed(status: Int)
    /// A downloaded model did not match its pinned sha256; it was removed (J-026).
    case checksumMismatch(file: String)
    /// No pinned sha256 for this model, so it is never downloaded (J-026).
    case notPinned(file: String)
}

/// The baseline on-device `Transcriber`: whisper.cpp, fed a 16 kHz WAV.
///
/// Raw audio and the disk: the `.server` backend builds the WAV in memory and posts the bytes, so nothing is
/// written. The `.cli` fallback is the one exception — whisper-cli only reads `-f <path>`, so it writes a
/// short-lived `jarvis-*.wav` in the temporary directory and deletes it as soon as the run ends.
///
/// Deviations from the blueprint's signatures, on purpose:
/// - `Backend.cli(binary:model:)` rather than `.cli(binary:)`: whisper-cli loads the model on every run (`-m`),
///   so the backend carries it; `.server` gets it from its `WhisperServerProcess`.
/// - `init(backend:language:session:)`: `language` defaults to `"auto"` (auto-detect) and `session` exists so tests
///   can stub `/inference`.
/// - `WhisperModelDownloader.download(_:into:progress:)` keeps the ticket's unlabelled first parameter rather
///   than the blueprint's `download(name:into:progress:)`.
public final class WhisperTranscriber: Transcriber {
    public enum Backend {
        /// A running `whisper-server` (the default, D-5).
        case server(WhisperServerProcess)
        /// One-shot `whisper-cli` per chunk (reloads the model each time — the fallback, D-5).
        case cli(binary: URL, model: URL)
    }

    public let backend: Backend
    public let language: String
    private let session: URLSession

    public init(backend: Backend, language: String = "auto", session: URLSession = .shared) {
        self.backend = backend
        self.language = language
        self.session = session
    }

    /// `whisper (ggml-small.bin)`, for settings and logs.
    public var displayName: String {
        switch backend {
        case let .server(server): return "whisper (\(server.model.lastPathComponent))"
        case let .cli(_, model): return "whisper (\(model.lastPathComponent))"
        }
    }

    public func transcribe(_ chunk: AudioChunk) async throws -> String {
        switch backend {
        case let .server(server):
            if let failure = server.failure { throw failure }
            return Self.clean(try await post(wav: try WAVWriter.data(for: chunk),
                                             to: server.baseURL.appending(path: "inference")))
        case let .cli(binary, model):
            let wav = FileManager.default.temporaryDirectory.appending(path: "jarvis-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            try WAVWriter.write(chunk, to: wav)
            return Self.clean(try await runCLI(binary: binary, model: model, wav: wav))
        }
    }

    // Field names confirmed from `whisper-server`'s built-in usage page and the whisper.cpp 1.9.5 README.
    private func post(wav: Data, to url: URL) async throws -> String {
        let boundary = "jarvis-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"jarvis-\(UUID().uuidString).wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n".utf8))
        field("language", language)
        field("response_format", "text")
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw WhisperError.serverFailed(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return String(decoding: data, as: UTF8.self)
    }

    // Flags confirmed with `whisper-cli --help` (whisper.cpp 1.9.5): -nt no timestamps, -np results only.
    private func runCLI(binary: URL, model: URL, wav: URL) async throws -> String {
        let output = try await ChildProcess.run(binary, arguments: ["-m", model.path, "-f", wav.path, "-l", language,
                                                                    "-nt", "-np"])
        guard output.status == 0 else {
            throw WhisperError.cliFailed(status: output.status, stderr: String(decoding: output.stderr, as: UTF8.self))
        }
        return String(decoding: output.stdout, as: UTF8.self)
    }

    /// Drops bracket-only tokens (`[BLANK_AUDIO]`, `[Music]`), joins lines, collapses whitespace.
    static func clean(_ raw: String) -> String {
        TranscriptText.clean(raw)
    }
}
