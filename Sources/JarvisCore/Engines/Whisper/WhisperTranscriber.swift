import Foundation

public enum WhisperError: Error, Equatable {
    case audioConversion
    case cliFailed(status: Int32, stderr: String)
    case serverFailed(status: Int, body: String)
    case serverNotReady
    case serverKeepsExiting
    case downloadFailed(status: Int)
}

/// The baseline on-device `Transcriber`: whisper.cpp, fed a temporary 16 kHz WAV deleted as soon as it is read.
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
        let wav = FileManager.default.temporaryDirectory.appending(path: "jarvis-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try WAVWriter.write(chunk, to: wav)
        switch backend {
        case let .server(server):
            if let failure = server.failure { throw failure }
            return Self.clean(try await post(wav: wav, to: server.baseURL.appending(path: "inference")))
        case let .cli(binary, model):
            return Self.clean(try await runCLI(binary: binary, model: model, wav: wav))
        }
    }

    // Field names confirmed from `whisper-server`'s built-in usage page and the whisper.cpp 1.9.5 README.
    private func post(wav: URL, to url: URL) async throws -> String {
        let boundary = "jarvis-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(wav.lastPathComponent)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: wav))
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
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-m", model.path, "-f", wav.path, "-l", language, "-nt", "-np"]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Both pipes are drained concurrently so a chatty stderr cannot block the child.
        async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
        async let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
        let (outData, errData) = await (out, err)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WhisperError.cliFailed(status: process.terminationStatus,
                                         stderr: String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: outData, as: UTF8.self)
    }

    /// Drops bracket-only tokens (`[BLANK_AUDIO]`, `[Music]`), joins lines, collapses whitespace.
    static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
