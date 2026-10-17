import AVFAudio
import Foundation
import Testing
import JarvisCore

/// Answers every chunk with the same line and counts the calls.
final class ImportFakeTranscriber: Transcriber {
    private(set) var calls = 0

    func transcribe(_ chunk: AudioChunk) async throws -> String {
        calls += 1
        return "Ship it Friday."
    }
}

/// Answers the first `succeeding` chunks, then fails every later one.
final class ImportFailingTranscriber: Transcriber {
    struct Failure: Error {}
    let succeeding: Int
    private var calls = 0

    init(succeeding: Int) { self.succeeding = succeeding }

    func transcribe(_ chunk: AudioChunk) async throws -> String {
        calls += 1
        if calls > succeeding { throw Failure() }
        return "Ship it Friday."
    }
}

@Suite struct ImportCoordinatorTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-import-\(UUID().uuidString)")
    let recordedAt = Date(timeIntervalSince1970: 1_792_000_000)

    var paths: JarvisPaths { JarvisPaths(root: root) }

    /// A `seconds`-long 440 Hz tone at speech level, 48 kHz mono, written to the inbox and dated
    /// `recordedAt` through the file's creation date (a plain WAV carries no recording-date metadata).
    func importWAV(seconds: Double, name: String = "memo.wav") throws -> URL {
        try FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
        let url = paths.inbox.appending(path: name)
        let rate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = 0.14 * Float(sin(2 * Double.pi * 440 * Double(i) / rate))
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        try FileManager.default.setAttributes([.creationDate: recordedAt], ofItemAtPath: url.path)
        return url
    }

    func makeCoordinator(transcriber: any Transcriber = ImportFakeTranscriber(), settleDelay: TimeInterval = 2,
                         onImported: @escaping (DateInterval) async -> Void = { _ in }) -> (ImportCoordinator, TranscriptStore) {
        let store = TranscriptStore(paths: paths)
        let pipeline = CapturePipeline(transcriber: transcriber, store: store)
        return (ImportCoordinator(pipeline: pipeline, settleDelay: settleDelay, onImported: onImported), store)
    }

    func allLines(_ store: TranscriptStore) throws -> [TranscriptLine] {
        try store.lines(in: DateInterval(start: recordedAt.addingTimeInterval(-3600), duration: 7200))
    }

    // QA-81, QA-82: a 65 s recording becomes three lines dated from the recording, then the copy is gone.
    @Test func importedRecordingIsTranscribedAtItsRecordingTimeAndDeleted() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try importWAV(seconds: 65)
        var imported: [DateInterval] = []
        let (coordinator, store) = makeCoordinator { imported.append($0) }

        let report = try await coordinator.importFile(url)

        let lines = try store.lines(in: DateInterval(start: recordedAt.addingTimeInterval(-3600), duration: 7200))
        #expect(lines.map(\.time) == [recordedAt, recordedAt.addingTimeInterval(30), recordedAt.addingTimeInterval(60)])
        #expect(lines.allSatisfy { $0.label == .me })
        #expect(report.lines == 3)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(imported.count == 1)
        #expect(imported.first?.start == recordedAt)
        #expect(abs((imported.first?.duration ?? 0) - 65) < 0.5)
    }

    // A failure after the first stored line still deletes the copy, so a retry cannot duplicate lines.
    @Test func failureAfterTheFirstLineStillDeletesTheFile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try importWAV(seconds: 65)
        var imported = 0
        let (coordinator, store) = makeCoordinator(transcriber: ImportFailingTranscriber(succeeding: 1)) { _ in imported += 1 }

        await #expect(throws: ImportFailingTranscriber.Failure.self) { try await coordinator.importFile(url) }

        #expect(try allLines(store).map(\.time) == [recordedAt])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(imported == 0)
    }

    // A failure before any line is stored keeps the file, so the next scan can try again.
    @Test func failureBeforeAnyLineKeepsTheFile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try importWAV(seconds: 10)
        let (coordinator, store) = makeCoordinator(transcriber: ImportFailingTranscriber(succeeding: 0))

        await #expect(throws: ImportFailingTranscriber.Failure.self) { try await coordinator.importFile(url) }

        #expect(try allLines(store).isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // QA-83: a scan imports supported recordings and leaves every other file alone.
    @Test func scanImportsSupportedRecordingsOnly() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = try importWAV(seconds: 5)
        let notes = paths.inbox.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: notes)
        let (coordinator, store) = makeCoordinator(settleDelay: 0.1)

        let reports = await coordinator.scanAndImport(folder: paths.inbox)

        #expect(reports.map(\.lines) == [1])
        #expect(try allLines(store).map(\.time) == [recordedAt])
        #expect(!FileManager.default.fileExists(atPath: wav.path))
        #expect(FileManager.default.fileExists(atPath: notes.path))
    }

    // A burst of files landing in the folder is one change, reported after the quiet period.
    @Test func folderWatcherReportsABurstOfWritesOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
        let watcher = DispatchFolderWatcher(url: paths.inbox, debounce: 0.3)
        let counter = ImportCallCounter()
        watcher.onChange = { counter.increment() }
        try watcher.start()
        defer { watcher.stop() }

        for i in 0..<3 {
            try Data("x".utf8).write(to: paths.inbox.appending(path: "f\(i).wav"))
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)

        #expect(counter.value == 1)
    }
}

final class ImportCallCounter {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
