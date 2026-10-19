import AVFAudio
import Foundation
import Testing
@testable import JarvisCore

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
    private(set) var calls = 0

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
        // Written and dated outside the inbox, then moved in whole, so no scan sees it half-written or undated.
        let staging = root.appending(path: "staging-\(UUID().uuidString)-\(name)")
        do {
            let file = try AVAudioFile(forWriting: staging, settings: format.settings)
            try file.write(from: buffer)
        }
        try FileManager.default.setAttributes([.creationDate: recordedAt], ofItemAtPath: staging.path)
        // rename(2): atomic, and it replaces a file already at `url`.
        guard rename(staging.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    func makeCoordinator(transcriber: any Transcriber = ImportFakeTranscriber(), settleDelay: TimeInterval = 2,
                         scheduler: any Scheduler = SystemScheduler(), progress: ImportProgress = ImportProgress(file: nil),
                         onImported: @escaping (DateInterval) async -> Void = { _ in }) -> (ImportCoordinator, TranscriptStore) {
        makeCoordinator(installed: { transcriber }, settleDelay: settleDelay, scheduler: scheduler, progress: progress,
                        onImported: onImported)
    }

    /// `installed` is read per chunk, as the facade's swappable transcriber is (DEC-5).
    func makeCoordinator(installed: @escaping () -> (any Transcriber)?, settleDelay: TimeInterval = 2,
                         scheduler: any Scheduler = SystemScheduler(), progress: ImportProgress = ImportProgress(file: nil),
                         onImported: @escaping (DateInterval) async -> Void = { _ in }) -> (ImportCoordinator, TranscriptStore) {
        let store = TranscriptStore(paths: paths)
        let pipeline = CapturePipeline(transcriber: installed, store: store)
        return (ImportCoordinator(pipeline: pipeline, settleDelay: settleDelay, scheduler: scheduler, progress: progress,
                                  onImported: onImported), store)
    }

    /// The progress file Jarvis keeps; a new instance over it is what a relaunch reads.
    var progressFile: URL { paths.importProgress }

    func allLines(_ store: TranscriptStore) throws -> [TranscriptLine] {
        try store.lines(in: DateInterval(start: recordedAt.addingTimeInterval(-3600), duration: 7200))
    }

    func makeImporter(_ coordinator: ImportCoordinator, retryDelay: TimeInterval = 60, maxRetries: Int = 12,
                      watcher: FakeFolderWatcher = FakeFolderWatcher(), scheduler: any Scheduler = SystemScheduler()) -> InboxImporter {
        InboxImporter(paths: paths, coordinator: coordinator, watcher: watcher,
                      retryDelay: retryDelay, maxRetries: maxRetries, scheduler: scheduler)
    }

    /// Moves virtual time on once something is waiting on it.
    func advance(_ clock: VirtualScheduler, by seconds: TimeInterval) async {
        #expect(await clock.waitForPending())
        clock.advance(by: seconds)
    }

    func inboxRecordings() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.inbox.path)) ?? []).filter { $0.hasSuffix(".wav") }
    }

    /// Polls `condition` every 50 ms for up to `timeout` seconds.
    func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
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

    // DEC-23: a failure after the first stored line keeps the file, and the stored part is still reported
    // so its hourly note gets written. The retry carries on after the stored part, so no line is doubled.
    @Test func failureAfterTheFirstLineKeepsTheFileAndTheRetryStoresOnlyTheRest() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try importWAV(seconds: 65)
        var imported: [DateInterval] = []
        var installed: any Transcriber = ImportFailingTranscriber(succeeding: 1)
        let (coordinator, store) = makeCoordinator(installed: { installed }) { imported.append($0) }

        await #expect(throws: ImportFailingTranscriber.Failure.self) { try await coordinator.importFile(url) }

        #expect(try allLines(store).map(\.time) == [recordedAt])
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(imported == [DateInterval(start: recordedAt, duration: 30)])

        installed = ImportFakeTranscriber()
        try await coordinator.importFile(url)

        #expect(try allLines(store).map(\.time) == [recordedAt, recordedAt.addingTimeInterval(30),
                                                    recordedAt.addingTimeInterval(60)])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // DEC-23: with no transcriber installed nothing is heard, so the recording is kept, not deleted, and
    // imports once speech exists.
    @Test func noTranscriberKeepsTheFileUntilOneIsInstalled() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try importWAV(seconds: 5)
        var imported: [DateInterval] = []
        var installed: (any Transcriber)?
        let (coordinator, store) = makeCoordinator(installed: { installed }) { imported.append($0) }

        await #expect(throws: ImportCoordinator.NoTranscriber.self) { try await coordinator.importFile(url) }

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try allLines(store).isEmpty)
        #expect(imported.isEmpty)

        installed = ImportFakeTranscriber()
        try await coordinator.importFile(url)

        #expect(try allLines(store).map(\.time) == [recordedAt])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // DEC-23: an empty result (a silent recording) is a successful transcription, so the file is deleted.
    @Test func anEmptyTranscriptionStillDeletesTheFile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try importWAV(seconds: 5)
        let (coordinator, store) = makeCoordinator(transcriber: CapturePipelineFakeTranscriber(reply: ""))

        let report = try await coordinator.importFile(url)

        #expect(report.lines == 0)
        #expect(try allLines(store).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
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

    // A delete that fails is reported, and a later scan does not import the same lines again.
    @Test func failedDeleteIsReportedAndNotImportedTwice() async throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.inbox.path)
            try? FileManager.default.removeItem(at: root)
        }
        let url = try importWAV(seconds: 5)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.inbox.path)
        let (coordinator, store) = makeCoordinator(settleDelay: 0.05)

        await #expect(throws: ImportError.self) { try await coordinator.importFile(url) }
        await coordinator.scanAndImport(folder: paths.inbox)

        #expect(try allLines(store).map(\.time) == [recordedAt])
        #expect(FileManager.default.fileExists(atPath: url.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.inbox.path)
        await coordinator.scanAndImport(folder: paths.inbox)

        #expect(try allLines(store).map(\.time) == [recordedAt])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // J-023: where an import got to is kept on disk, so a relaunch carries on after the chunks already stored,
    // and a recording whose delete failed is not imported again. Neither stores a line twice.
    @Test func aRelaunchCarriesOnAfterTheChunksAlreadyStored() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try importWAV(seconds: 65)  // three chunks
        let (before, _) = makeCoordinator(transcriber: ImportFailingTranscriber(succeeding: 1),
                                          progress: ImportProgress(file: progressFile))
        await #expect(throws: ImportFailingTranscriber.Failure.self) { try await before.importFile(url) }

        // Jarvis quits and relaunches: nothing in memory survives.
        let transcriber = ImportFakeTranscriber()
        let (after, store) = makeCoordinator(transcriber: transcriber, progress: ImportProgress(file: progressFile))
        try await after.importFile(url)

        #expect(transcriber.calls == 2)
        #expect(try allLines(store).map(\.time) == [0, 30, 60].map { recordedAt.addingTimeInterval($0) })
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(ImportProgress(file: progressFile).isEmpty)  // done with: nothing left behind
    }

    @Test func aRecordingWhoseDeleteFailedIsNotImportedAgainAfterARelaunch() async throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.inbox.path)
            try? FileManager.default.removeItem(at: root)
        }
        let url = try importWAV(seconds: 5)
        try FileManager.default.createDirectory(at: paths.index, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.inbox.path)
        let (before, _) = makeCoordinator(settleDelay: 0.05, progress: ImportProgress(file: progressFile))
        await #expect(throws: ImportError.self) { try await before.importFile(url) }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.inbox.path)
        let transcriber = ImportFakeTranscriber()
        let (after, store) = makeCoordinator(transcriber: transcriber, settleDelay: 0.05,
                                             progress: ImportProgress(file: progressFile))
        await after.scanAndImport(folder: paths.inbox)

        #expect(transcriber.calls == 0)
        #expect(try allLines(store).map(\.time) == [recordedAt])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func progressIsForOneVersionOfAFile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try importWAV(seconds: 65)
        let (before, _) = makeCoordinator(transcriber: ImportFailingTranscriber(succeeding: 1),
                                          progress: ImportProgress(file: progressFile))
        await #expect(throws: ImportFailingTranscriber.Failure.self) { try await before.importFile(url) }

        _ = try importWAV(seconds: 65)  // a different recording under the same name
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        let transcriber = ImportFakeTranscriber()
        let (after, _) = makeCoordinator(transcriber: transcriber, progress: ImportProgress(file: progressFile))
        try await after.importFile(url)

        #expect(transcriber.calls == 3)  // from its first chunk
    }

    // A file that cannot be decoded is moved to inbox/failed after its first try, so it is not retried forever.
    @Test func undecodableFileIsMovedToTheFailedFolder() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
        let url = paths.inbox.appending(path: "broken.m4a")
        try Data("not audio at all".utf8).write(to: url)
        let (coordinator, store) = makeCoordinator()

        await #expect(throws: (any Error).self) { try await coordinator.importFile(url) }

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: paths.inbox.appending(path: "failed/broken.m4a").path))
        #expect(try allLines(store).isEmpty)
    }

    // F-4: one scan at a time; changes during a scan become one more scan; nothing is imported twice.
    @Test func inboxImporterRunsOneScanAtATimeAndCoalescesChanges() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try importWAV(seconds: 5, name: "a.wav")
        let transcriber = ImportFakeTranscriber()
        let (coordinator, store) = makeCoordinator(transcriber: transcriber, settleDelay: 0.4)
        let watcher = FakeFolderWatcher()
        let importer = makeImporter(coordinator, watcher: watcher)
        try importer.start()

        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try importWAV(seconds: 5, name: "b.wav")
        for _ in 0..<3 { watcher.fire() }
        await waitUntil { inboxRecordings().isEmpty }
        await importer.stop()

        #expect(inboxRecordings().isEmpty)
        #expect(transcriber.calls == 2)
        #expect(try allLines(store).count == 2)
    }

    // F-4: stop() cancels the scan in flight and waits for it, so nothing is imported after it returns.
    @Test func inboxImporterStopCancelsTheScanInFlight() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try importWAV(seconds: 5)
        let transcriber = ImportFakeTranscriber()
        let (coordinator, _) = makeCoordinator(transcriber: transcriber, settleDelay: 0.5)
        let importer = makeImporter(coordinator)
        try importer.start()

        try await Task.sleep(nanoseconds: 100_000_000)
        await importer.stop()
        try await Task.sleep(nanoseconds: 800_000_000)

        #expect(transcriber.calls == 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // F-2: a file still being copied when a scan runs is retried without another folder change.
    @Test func inboxImporterRetriesAFileStillBeingCopied() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
        let url = paths.inbox.appending(path: "memo.wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let clock = VirtualScheduler()
        let transcriber = ImportFakeTranscriber()
        let (coordinator, store) = makeCoordinator(transcriber: transcriber, settleDelay: 0.1, scheduler: clock)
        let importer = makeImporter(coordinator, retryDelay: 0.3, scheduler: clock)
        try importer.start()

        await advance(clock, by: 0.1)  // the first scan's settle look: the empty file is still copying
        #expect(await clock.waitForPending())  // so a retry waits
        #expect(transcriber.calls == 0)
        // The copy completes over the empty file in one step, as a finished copy does.
        _ = try importWAV(seconds: 5)
        clock.advance(by: 0.3)  // the retry
        await advance(clock, by: 0.1)  // its settle look
        await waitUntil { inboxRecordings().isEmpty }
        await importer.stop()

        #expect(inboxRecordings().isEmpty)
        #expect(try allLines(store).map(\.time) == [recordedAt])
    }

    // F-2: a file kept after a failure is retried, but only `maxRetries` times without a folder change.
    @Test func inboxImporterStopsRetryingAfterItsBound() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try importWAV(seconds: 5)
        let transcriber = ImportFailingTranscriber(succeeding: 0)
        let clock = VirtualScheduler()
        let (coordinator, _) = makeCoordinator(transcriber: transcriber, settleDelay: 0.05, scheduler: clock)
        let importer = makeImporter(coordinator, retryDelay: 0.1, maxRetries: 2, scheduler: clock)
        try importer.start()

        for _ in 0..<2 {
            await advance(clock, by: 0.05)  // settle look, then the try fails
            await advance(clock, by: 0.1)  // the retry
        }
        await advance(clock, by: 0.05)
        await waitUntil { importer.scanIsIdle }
        #expect(clock.pending == 0)  // no fourth try is scheduled
        clock.advance(by: 3600)
        await importer.stop()

        #expect(transcriber.calls == 3)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // QA-83: a scan imports supported recordings and leaves every other file alone.
    @Test func scanImportsSupportedRecordingsOnly() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = try importWAV(seconds: 5)
        let notes = paths.inbox.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: notes)
        let (coordinator, store) = makeCoordinator(settleDelay: 0.1)

        let scan = await coordinator.scanAndImport(folder: paths.inbox)

        #expect(scan.imported.map(\.lines) == [1])
        #expect(scan.waiting == 0)
        #expect(try allLines(store).map(\.time) == [recordedAt])
        #expect(!FileManager.default.fileExists(atPath: wav.path))
        #expect(FileManager.default.fileExists(atPath: notes.path))
    }

    // A burst of files landing in the folder is one change, reported after the quiet period.
    @Test func folderWatcherReportsABurstOfWritesOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
        // Virtual time: however slowly the writes' events arrive, no debounce passes between them.
        let clock = VirtualScheduler()
        let watcher = DispatchFolderWatcher(url: paths.inbox, debounce: 1, scheduler: clock)
        let counter = ImportCallCounter()
        watcher.onChange = { counter.increment() }
        try watcher.start()
        defer { watcher.stop() }

        for i in 0..<3 {
            try Data("x".utf8).write(to: paths.inbox.appending(path: "f\(i).wav"))
        }
        #expect(await clock.waitForPending())
        try await Task.sleep(nanoseconds: 100_000_000)  // let the events still in flight reschedule
        #expect(clock.pending == 1)
        clock.advance(by: 0.9)
        #expect(clock.pending == 1)  // not before the debounce: still waiting
        #expect(counter.value == 0)
        clock.advance(by: 0.1)
        await waitUntil { counter.value == 1 }

        #expect(counter.value == 1)
        #expect(clock.pending == 0)
    }

    // F-7: stop() called from inside onChange returns instead of deadlocking on the watcher's queue.
    @Test func folderWatcherCanBeStoppedFromInsideOnChange() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
        let watcher = DispatchFolderWatcher(url: paths.inbox, debounce: 0.1)
        let counter = ImportCallCounter()
        watcher.onChange = { watcher.stop(); counter.increment() }
        try watcher.start()

        try Data("x".utf8).write(to: paths.inbox.appending(path: "f.wav"))
        try await Task.sleep(nanoseconds: 600_000_000)

        #expect(counter.value == 1)
    }
}

final class ImportCallCounter {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// A watcher the test fires by hand.
final class FakeFolderWatcher: FolderWatcher {
    var onChange: (() -> Void)?
    func start() throws {}
    func stop() {}
    func fire() { onChange?() }
}

