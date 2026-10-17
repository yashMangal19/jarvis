import Foundation

/// What one import produced.
public struct ImportReport {
    public let lines: Int
    /// From the recording's start to its end, in recording time.
    public let period: DateInterval
}

/// What one scan of the inbox did.
public struct ScanReport {
    public let imported: [ImportReport]
    /// Recordings still in the inbox afterwards (still copying, or kept after a failure).
    public let waiting: Int
}

/// Transcribes recordings dropped into a folder, dated by when they were recorded, and deletes each once
/// it is fully transcribed.
public final class ImportCoordinator {
    /// No transcriber is installed yet; the recording is kept for a later scan (DEC-23).
    public struct NoTranscriber: Error {}

    private let pipeline: CapturePipeline
    private let onImported: (DateInterval) async -> Void
    private let settleDelay: TimeInterval
    private let lock = NSLock()
    /// Files whose lines are stored but whose delete failed; never imported again, deleted on a later scan.
    private var undeleted: Set<FileStamp> = []
    /// Files kept after a failure, with how many of their chunks are already stored.
    private var resumeAt: [FileStamp: Int] = [:]

    /// `onImported` receives the stored period of the recording; the facade hands it to
    /// `HourlyNoteScheduler.renote`, which notes again the finished hours it touched.
    /// `settleDelay` is how long a file's size must stay unchanged before `scanAndImport` takes it.
    public init(pipeline: CapturePipeline, settleDelay: TimeInterval = 2,
                onImported: @escaping (DateInterval) async -> Void) {
        self.pipeline = pipeline
        self.settleDelay = settleDelay
        self.onImported = onImported
    }

    /// Decodes `url`, transcribes every chunk, reports the period, then deletes `url`.
    ///
    /// User audio is deleted only after its whole transcription succeeded (DEC-23); an empty result
    /// (a silent recording) counts as success. So:
    /// - a chunk failing, or no transcriber installed (`NoTranscriber`), keeps the file for the next scan;
    ///   the stored part (start to the end of the last stored chunk) is still reported, and the next try
    ///   of the same file carries on after the chunks already stored, so no line is stored twice.
    ///   Ceiling: that place is kept in memory, so a retry after a relaunch starts from the beginning;
    /// - a file that cannot be decoded is moved to `failed/` beside it, so it is not retried forever,
    ///   and `ImportError.undecodable` says where it went;
    /// - a failed delete throws `ImportError.notDeleted`, and the file is never imported again.
    @discardableResult
    public func importFile(_ url: URL) async throws -> ImportReport {
        let stamp = FileStamp(url)
        let recordedAt = await RecordingDate.of(url)
        let chunks: [AudioChunk]
        do { chunks = try AudioFileDecoder.chunks(from: url, recordedAt: recordedAt) } catch {
            throw ImportError.undecodable(movedTo: moveToFailed(url), error)
        }
        let alreadyStored = lock.withLock { resumeAt[stamp] ?? 0 }
        var lines = 0
        var storedEnd = recordedAt
        for (index, chunk) in chunks.enumerated().dropFirst(alreadyStored) {
            do {
                switch try await pipeline.process(chunk) {
                case .noTranscriber: throw NoTranscriber()
                case .transcribed:
                    lines += 1
                    storedEnd = chunk.start.addingTimeInterval(chunk.duration)
                case .dropped, .empty: break
                }
            } catch {
                lock.withLock { resumeAt[stamp] = index }
                if lines > 0 { await onImported(DateInterval(start: recordedAt, end: storedEnd)) }
                throw error
            }
        }
        let period = DateInterval(start: recordedAt, duration: chunks.reduce(0) { $0 + $1.duration })
        await onImported(period)
        try delete(url, stamp)
        return ImportReport(lines: lines, period: period)
    }

    /// Imports every supported file in `folder` whose size is unchanged across two looks
    /// `settleDelay` apart, so a file still being copied in is left for the next scan.
    /// A file that fails is skipped; the others still import. Stops between files when cancelled.
    @discardableResult
    public func scanAndImport(folder: URL) async -> ScanReport {
        var reports: [ImportReport] = []
        for url in await ScanScheduler.settledFiles(after: settleDelay, { sizes(in: folder) }) {
            if Task.isCancelled { break }
            let stamp = FileStamp(url)
            if lock.withLock({ undeleted.contains(stamp) }) {
                try? delete(url, stamp)
            } else if let report = try? await importFile(url) {
                reports.append(report)
            }
        }
        return ScanReport(imported: reports, waiting: sizes(in: folder).count)
    }

    private func delete(_ url: URL, _ stamp: FileStamp) throws {
        do {
            try FileManager.default.removeItem(at: url)
            lock.withLock {
                undeleted.remove(stamp)
                resumeAt[stamp] = nil
            }
        } catch {
            _ = lock.withLock { undeleted.insert(stamp) }
            throw ImportError.notDeleted(url, error)
        }
    }

    /// Where `url` now is, or nil when the move failed and it is still in place.
    private func moveToFailed(_ url: URL) -> URL? {
        let failed = url.deletingLastPathComponent().appending(path: "failed")
        try? FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
        var target = failed.appending(path: url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            target = failed.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        }
        do { try FileManager.default.moveItem(at: url, to: target) } catch { return nil }
        return target
    }

    private func sizes(in folder: URL) -> [URL: Int] {
        ScanScheduler.sizes(in: folder) { AudioFileDecoder.supportedExtensions.contains($0.pathExtension.lowercased()) }
    }
}

/// A file as it was when imported: a new file under the same name is a different stamp.
/// Also used by `VoiceMemosImporter` to tell a memo still being written from a broken one.
struct FileStamp: Hashable {
    let path: String
    let size: Int?
    let modified: Date?

    init(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        path = url.standardizedFileURL.path
        size = values?.fileSize
        modified = values?.contentModificationDate
    }
}
