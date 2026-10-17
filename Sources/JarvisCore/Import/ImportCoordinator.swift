import Foundation

/// What one import produced.
public struct ImportReport {
    public let lines: Int
    /// From the recording's start to its end, in recording time.
    public let period: DateInterval
}

/// Transcribes recordings dropped into a folder, dated by when they were recorded, and deletes them.
public final class ImportCoordinator {
    private let pipeline: CapturePipeline
    private let onImported: (DateInterval) async -> Void
    private let settleDelay: TimeInterval

    /// `onImported` receives the recording's period once every chunk is transcribed; the facade
    /// routes it to the hourly note for each clock hour it touches.
    /// `settleDelay` is how long a file's size must stay unchanged before `scanAndImport` takes it.
    public init(pipeline: CapturePipeline, settleDelay: TimeInterval = 2,
                onImported: @escaping (DateInterval) async -> Void) {
        self.pipeline = pipeline
        self.settleDelay = settleDelay
        self.onImported = onImported
    }

    /// Decodes `url`, transcribes every chunk, then deletes `url`. The file is also deleted when a
    /// later chunk fails once a line is stored, so a retry cannot duplicate lines; it is kept when
    /// nothing was stored, so the next scan can try again.
    @discardableResult
    public func importFile(_ url: URL) async throws -> ImportReport {
        let recordedAt = await RecordingDate.of(url)
        let chunks = try AudioFileDecoder.chunks(from: url, recordedAt: recordedAt)
        var lines = 0
        var finished = false
        defer { if finished || lines > 0 { try? FileManager.default.removeItem(at: url) } }
        for chunk in chunks {
            if case .transcribed = try await pipeline.process(chunk) { lines += 1 }
        }
        finished = true
        let period = DateInterval(start: recordedAt, duration: chunks.reduce(0) { $0 + $1.duration })
        await onImported(period)
        return ImportReport(lines: lines, period: period)
    }

    /// Imports every supported file in `folder` whose size is unchanged across two looks
    /// `settleDelay` apart, so a file still being copied in is left for the next scan.
    /// A file that fails is skipped; the others still import.
    @discardableResult
    public func scanAndImport(folder: URL) async -> [ImportReport] {
        let before = sizes(in: folder)
        try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        let after = sizes(in: folder)
        var reports: [ImportReport] = []
        for (url, size) in after.sorted(by: { $0.key.path < $1.key.path }) where size > 0 && before[url] == size {
            if let report = try? await importFile(url) { reports.append(report) }
        }
        return reports
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
