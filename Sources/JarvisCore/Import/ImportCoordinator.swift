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

/// Transcribes recordings dropped into a folder, dated by when they were recorded, and deletes them.
public final class ImportCoordinator {
    private let pipeline: CapturePipeline
    private let onImported: (DateInterval) async -> Void
    private let settleDelay: TimeInterval
    private let lock = NSLock()
    /// Files whose lines are stored but whose delete failed; never imported again, deleted on a later scan.
    private var undeleted: Set<FileStamp> = []

    /// `onImported` receives the stored period of the recording; the facade routes it to the
    /// hourly note for each clock hour it touches.
    /// `settleDelay` is how long a file's size must stay unchanged before `scanAndImport` takes it.
    public init(pipeline: CapturePipeline, settleDelay: TimeInterval = 2,
                onImported: @escaping (DateInterval) async -> Void) {
        self.pipeline = pipeline
        self.settleDelay = settleDelay
        self.onImported = onImported
    }

    /// Decodes `url`, transcribes every chunk, reports the period, then deletes `url`.
    ///
    /// Deviation from the blueprint ("nothing of the audio survives"): user audio is only deleted
    /// once a line of it is stored. So:
    /// - a later chunk failing after a line is stored still deletes the file (a retry cannot
    ///   duplicate lines), and the stored part (start to the end of the last stored chunk) is reported;
    /// - a failure before any line is stored keeps the file for the next scan;
    /// - a file that cannot be decoded is moved to `failed/` beside it, so it is not retried forever;
    /// - a failed delete throws `ImportError.notDeleted`, and the file is never imported again.
    @discardableResult
    public func importFile(_ url: URL) async throws -> ImportReport {
        let stamp = FileStamp(url)
        let recordedAt = await RecordingDate.of(url)
        let chunks: [AudioChunk]
        do { chunks = try AudioFileDecoder.chunks(from: url, recordedAt: recordedAt) } catch {
            moveToFailed(url)
            throw error
        }
        var lines = 0
        var storedEnd = recordedAt
        do {
            for chunk in chunks {
                if case .transcribed = try await pipeline.process(chunk) {
                    lines += 1
                    storedEnd = chunk.start.addingTimeInterval(chunk.duration)
                }
            }
        } catch {
            if lines > 0 {
                await onImported(DateInterval(start: recordedAt, end: storedEnd))
                try delete(url, stamp)
            }
            throw error
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
        let before = sizes(in: folder)
        try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        let after = sizes(in: folder)
        var reports: [ImportReport] = []
        for (url, size) in after.sorted(by: { $0.key.path < $1.key.path }) where size > 0 && before[url] == size {
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
            _ = lock.withLock { undeleted.remove(stamp) }
        } catch {
            _ = lock.withLock { undeleted.insert(stamp) }
            throw ImportError.notDeleted(url, error)
        }
    }

    private func moveToFailed(_ url: URL) {
        let failed = url.deletingLastPathComponent().appending(path: "failed")
        try? FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
        var target = failed.appending(path: url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            target = failed.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        }
        try? FileManager.default.moveItem(at: url, to: target)
    }

    private func sizes(in folder: URL) -> [URL: Int] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)) ?? []
        var sizes: [URL: Int] = [:]
        for url in files where AudioFileDecoder.supportedExtensions.contains(url.pathExtension.lowercased()) {
            sizes[url] = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }
        return sizes
    }
}

/// A file as it was when imported: a new file under the same name is a different stamp.
private struct FileStamp: Hashable {
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
