import Foundation

/// Downloads ggml models from the whisper.cpp Hugging Face repo, at a pinned revision, into the models folder.
/// Fails closed: only pinned models are fetched, and a file whose sha256 differs is removed, never used (DEC-53).
public final class WhisperModelDownloader {
    private let configuration: URLSessionConfiguration
    private let pins: WhisperModels.Pins

    public init(configuration: URLSessionConfiguration = .default, pins: WhisperModels.Pins = WhisperModels.pinned) {
        self.configuration = configuration
        self.pins = pins
    }

    /// `ggml-small.bin` in `models`, downloaded first if absent.
    public func ensureSmall(in models: URL, progress: ((Double) -> Void)? = nil) async throws -> URL {
        let file = models.appending(path: "ggml-small.bin")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        return try await download("small", into: models, progress: progress)
    }

    /// Fetches `ggml-<name>.bin` to `<file>.part`, renamed once its sha256 matches the pin, so a half or wrong
    /// download never looks like a model. `progress` gets 0…1 on a background queue.
    public func download(_ name: String, into models: URL, progress: ((Double) -> Void)? = nil) async throws -> URL {
        let fileName = "ggml-\(name).bin"
        guard let expected = pins.files[fileName] else { throw WhisperError.notPinned(file: fileName) }
        let file = models.appending(path: fileName)
        let part = models.appending(path: fileName + ".part")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)

        let delegate = DownloadDelegate(part: part, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: pins.url(for: fileName)).resume()
        }
        guard try WhisperModels.sha256Hex(of: part) == expected else {
            try? FileManager.default.removeItem(at: part)
            throw WhisperError.checksumMismatch(file: fileName)
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: part, to: file)
        progress?(1)
        return file
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let part: URL
    let progress: ((Double) -> Void)?
    var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(part: URL, progress: ((Double) -> Void)?) {
        self.part = part
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    // `location` is deleted when this returns, so the move happens here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { failure = WhisperError.downloadFailed(status: status); return }
        do {
            try? FileManager.default.removeItem(at: part)
            try FileManager.default.moveItem(at: location, to: part)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? failure { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }
}
