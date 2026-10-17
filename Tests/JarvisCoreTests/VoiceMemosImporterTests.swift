import AVFoundation
import Combine
import Foundation
import Testing
import JarvisCore

@Suite struct VoiceMemosImporterTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-memos-\(UUID().uuidString)")
    let recordedAt = Date(timeIntervalSince1970: 1_792_000_000)

    var paths: JarvisPaths { JarvisPaths(root: root) }
    /// Stands in for the Voice Memos "Recordings" folder.
    var recordings: URL { root.appending(path: "VoiceMemos/Recordings") }
    /// Outside the watched folder: fixtures built here cannot be seen by a scan half-made.
    var fixtures: URL { root.appending(path: "fixtures") }

    /// A `seconds`-long tone at speech level in `folder` (the fake Recordings folder), dated `recordedAt`.
    func memoM4A(seconds: Double = 3, name: String = "20261017 101500-AB12CD34.m4a", in folder: URL? = nil) throws -> URL {
        let folder = folder ?? recordings
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        let rate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = 0.14 * Float(sin(2 * Double.pi * 440 * Double(i) / rate))
        }
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                           AVNumberOfChannelsKey: 1]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
        }
        try FileManager.default.setAttributes([.creationDate: recordedAt], ofItemAtPath: url.path)
        return url
    }

    func memoImporter(access: VoiceMemosAccess? = nil, watcher: FakeFolderWatcher = FakeFolderWatcher(),
                      transcriber: any Transcriber = ImportFakeTranscriber(),
                      ledger: ImportLedger? = nil, retryDelay: TimeInterval = 60) -> (VoiceMemosImporter, TranscriptStore) {
        let store = TranscriptStore(paths: paths)
        let coordinator = ImportCoordinator(pipeline: CapturePipeline(transcriber: transcriber, store: store),
                                            onImported: { _ in })
        let access = access ?? .readable(recordings)
        let importer = VoiceMemosImporter(locator: { access }, watcherFactory: { _ in watcher },
                                          coordinator: coordinator, ledger: ledger ?? ImportLedger(paths: paths),
                                          paths: paths, settleDelay: 0.05, retryDelay: retryDelay)
        return (importer, store)
    }

    /// The lines within a day of `around`. A bounded window: the store reads one file per day in the
    /// interval, so `.distantPast…distantFuture` alone took about 9 s.
    func memoLines(_ store: TranscriptStore, around: Date) throws -> [TranscriptLine] {
        try store.lines(in: DateInterval(start: around.addingTimeInterval(-86_400), duration: 2 * 86_400))
    }

    /// Polls `condition` every 50 ms; records an issue if it is still false after `timeout` seconds.
    /// The deadline is generous: under a loaded full-suite run one import has taken over 9 s.
    func memoWaitUntil(timeout: TimeInterval = 60, _ condition: () -> Bool,
                       sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        if !condition() { Issue.record("timed out after \(timeout) s", sourceLocation: sourceLocation) }
    }

    /// Starts `importer` over an empty Recordings folder, so its baseline is empty and every memo
    /// written afterwards is new.
    func startEmpty(_ importer: VoiceMemosImporter) async throws {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try await importer.start()
    }

    @Test func importsACopyAndLeavesTheOriginalUntouched() async throws {
        let watcher = FakeFolderWatcher()
        let ledger = ImportLedger(paths: paths)
        let (importer, store) = memoImporter(watcher: watcher, ledger: ledger)
        try await startEmpty(importer)
        let original = try memoM4A()
        let bytes = try Data(contentsOf: original)
        // AVAudioFile stamps an m4a with its write time as creation metadata; a real memo carries its recording time.
        let recorded = await RecordingDate.of(original)
        let modified = try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        watcher.fire()
        await memoWaitUntil { ledger.isImported(original) }
        await importer.stop()

        #expect(ledger.isImported(original))
        #expect(try Data(contentsOf: original) == bytes)
        #expect(try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        let lines = try memoLines(store, around: recorded)
        #expect(lines.count == 1)
        #expect(lines.first?.time == TranscriptLine(time: recorded, label: .me, text: "").time)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.imports.path).filter { $0.hasSuffix(".m4a") }.isEmpty)
    }

    // F-2: recent Voice Memos also write QuickTime-container `.qta` memos; AVAudioFile decodes them.
    @Test func aQuickTimeMemoIsImported() async throws {
        let watcher = FakeFolderWatcher()
        let transcriber = ImportFakeTranscriber()
        let ledger = ImportLedger(paths: paths)
        let (importer, _) = memoImporter(watcher: watcher, transcriber: transcriber, ledger: ledger)
        // Built outside the watched folder, then moved in whole: the importer's first scan runs as soon as
        // it starts, and must find neither the source .m4a nor a half-exported .qta.
        let m4a = try memoM4A(name: "source.m4a", in: fixtures)
        let exported = fixtures.appending(path: "20261017 101500-QT12CD34.qta")
        guard #available(macOS 15, *) else { return }
        let export = try #require(AVAssetExportSession(asset: AVURLAsset(url: m4a), presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: exported, as: .mov) // a QuickTime ('qt  ') container, as .qta is
        try await startEmpty(importer)
        let qta = recordings.appending(path: exported.lastPathComponent)
        try FileManager.default.moveItem(at: exported, to: qta)

        watcher.fire()
        await memoWaitUntil { ledger.isImported(qta) }
        await importer.stop()

        #expect(transcriber.calls == 1)
    }

    @Test func aSecondChangeImportsNothing() async throws {
        let watcher = FakeFolderWatcher()
        let transcriber = ImportFakeTranscriber()
        let ledger = ImportLedger(paths: paths)
        let (importer, _) = memoImporter(watcher: watcher, transcriber: transcriber, ledger: ledger)
        try await startEmpty(importer)
        let original = try memoM4A()

        watcher.fire()
        await memoWaitUntil { ledger.isImported(original) }
        watcher.fire()
        try await Task.sleep(nanoseconds: 500_000_000)
        await importer.stop()

        #expect(transcriber.calls == 1)
        #expect(ImportLedger(paths: paths).isImported(original))
    }

    // Backlog decision A: memos already in the folder the first time it is readable are a baseline,
    // recorded as seen and never imported; only memos that appear afterwards are imported.
    @Test func memosAlreadyThereOnFirstStartAreABaselineAndOnlyLaterOnesImport() async throws {
        let old = [try memoM4A(name: "old-1.m4a"), try memoM4A(name: "old-2.m4a")]
        let watcher = FakeFolderWatcher()
        let transcriber = ImportFakeTranscriber()
        let ledger = ImportLedger(paths: paths)
        let (importer, _) = memoImporter(watcher: watcher, transcriber: transcriber, ledger: ledger)

        try await importer.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(transcriber.calls == 0)
        #expect(old.allSatisfy { ledger.isImported($0) })

        let later = try memoM4A(name: "later.m4a")
        watcher.fire()
        await memoWaitUntil { ledger.isImported(later) }
        await importer.stop()
        #expect(transcriber.calls == 1)

        // A relaunch over a fresh ledger read from the same file imports nothing old, and still imports
        // a memo that appears after it: one call, not three, so the file kept both the baseline and the import.
        let relaunchWatcher = FakeFolderWatcher()
        let relaunched = ImportFakeTranscriber()
        let relaunchLedger = ImportLedger(paths: paths)
        let (again, _) = memoImporter(watcher: relaunchWatcher, transcriber: relaunched, ledger: relaunchLedger)
        try await again.start()
        let afterRelaunch = try memoM4A(name: "after-relaunch.m4a")
        relaunchWatcher.fire()
        await memoWaitUntil { relaunchLedger.isImported(afterRelaunch) }
        await again.stop()
        #expect(relaunched.calls == 1)
    }

    // Backlog decision A, folder absent: with no Recordings folder at first start the baseline is empty,
    // so the first memo that syncs (and creates the folder) is imported, not taken as a baseline later.
    @Test func aMissingFolderAtFirstStartTakesAnEmptyBaselineSoTheFirstMemoImports() async throws {
        let watcher = FakeFolderWatcher()
        let transcriber = ImportFakeTranscriber()
        let ledger = ImportLedger(paths: paths)
        var access = VoiceMemosAccess.absent
        let store = TranscriptStore(paths: paths)
        let coordinator = ImportCoordinator(pipeline: CapturePipeline(transcriber: transcriber, store: store),
                                            onImported: { _ in })
        let importer = VoiceMemosImporter(locator: { access }, watcherFactory: { _ in watcher },
                                          coordinator: coordinator, ledger: ledger, paths: paths,
                                          settleDelay: 0.05, retryDelay: 60)

        try await importer.start()
        let first = try memoM4A(name: "first.m4a")
        access = .readable(recordings)
        try await importer.start() // re-probed once the first memo has synced
        watcher.fire()
        await memoWaitUntil(timeout: 10) { ledger.isImported(first) }
        await importer.stop()
        #expect(transcriber.calls == 1)

        let relaunched = ImportFakeTranscriber()
        let (again, _) = memoImporter(transcriber: relaunched, ledger: ImportLedger(paths: paths))
        try await again.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await again.stop()
        #expect(relaunched.calls == 0)
    }

    // A ledger written before baselines existed ({ path: { size, mtime } }) keeps its memos and still
    // takes a baseline of everything else already there.
    @Test func aLedgerWithoutABaselineMarkerTakesOneOnStart() async throws {
        let imported = try memoM4A(name: "imported.m4a")
        let present = try memoM4A(name: "present.m4a")
        try FileManager.default.createDirectory(at: paths.index, withIntermediateDirectories: true)
        try Data(#"{"\#(imported.standardizedFileURL.path)":{"size":10,"mtime":1792000000}}"#.utf8)
            .write(to: paths.index.appending(path: "imported.json"))
        let transcriber = ImportFakeTranscriber()
        let (importer, _) = memoImporter(transcriber: transcriber, ledger: ImportLedger(paths: paths))

        try await importer.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await importer.stop()

        #expect(transcriber.calls == 0)
        let reread = ImportLedger(paths: paths)
        #expect(reread.isImported(imported))
        #expect(reread.isImported(present))
    }

    @Test func anUnreadableFolderAsksForFullDiskAccess() async throws {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: recordings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recordings.path) }
        let missing = root.appending(path: "nowhere/Recordings")

        #expect(VoiceMemosLocator.probe([missing, recordings]) == .unreadable(recordings))
        #expect(VoiceMemosLocator.probe([missing]) == .absent)

        let (importer, _) = memoImporter(access: .unreadable(recordings))
        try await importer.start()
        #expect(importer.needsFullDiskAccess)
        await importer.stop()
    }

    // F-1: TCC refuses even the lookup of a protected folder, so a refusal is read from the listing's
    // own error, never from an existence check first.
    @Test func aRefusedListingIsUnreadableEvenWhenTheFolderCannotBeLookedUp() {
        let missing = root.appending(path: "nowhere/Recordings")
        let protected = root.appending(path: "protected/Recordings")
        let list: (URL) throws -> [String] = { url in
            throw url == protected ? POSIXError(.EPERM) : POSIXError(.ENOENT)
        }

        #expect(VoiceMemosLocator.probe([missing, protected], list: list) == .unreadable(protected))
        #expect(VoiceMemosLocator.probe([missing], list: list) == .absent)
        #expect(VoiceMemosLocator.probe([protected], list: { _ in throw POSIXError(.EACCES) }) == .unreadable(protected))
    }

    // F-6: the menu observes needsFullDiskAccess, so it changes on the main thread even when start()
    // is awaited from elsewhere.
    @Test func fullDiskAccessIsPublishedOnTheMainThread() async throws {
        let (importer, _) = memoImporter(access: .unreadable(recordings))
        var onMain: [Bool] = []
        let subscription = importer.$needsFullDiskAccess.dropFirst().sink { _ in onMain.append(Thread.isMainThread) }
        defer { subscription.cancel() }

        try await importer.start()
        await importer.stop()

        #expect(onMain == [true])
    }

    @Test func probeTakesTheFirstFolderThatExists() throws {
        let other = root.appending(path: "Legacy/Recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        #expect(VoiceMemosLocator.probe([root.appending(path: "nowhere"), other, recordings]) == .readable(other))
    }

    @Test func anUndecodableMemoIsRecordedAndLeavesNoCopy() async throws {
        let watcher = FakeFolderWatcher()
        let ledger = ImportLedger(paths: paths)
        let (importer, _) = memoImporter(watcher: watcher, ledger: ledger, retryDelay: 0.1)
        try await startEmpty(importer)
        let original = recordings.appending(path: "broken.m4a")
        try Data("not audio".utf8).write(to: original)

        watcher.fire()
        await memoWaitUntil { ledger.isImported(original) }
        await importer.stop()

        #expect(ledger.isImported(original))
        #expect(try Data(contentsOf: original) == Data("not audio".utf8))
        #expect(FileManager.default.subpaths(atPath: paths.imports.path)?.filter { $0.hasSuffix(".m4a") } == [])
    }

    // F-5: when failed/<name> is taken the copy lands under another name; that copy is the one removed,
    // and the file already there is left alone.
    @Test func anUndecodableMemoRemovesItsOwnFailedCopyWhenTheNameIsTaken() async throws {
        let failed = paths.imports.appending(path: "failed")
        try FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
        try Data("older".utf8).write(to: failed.appending(path: "broken.m4a"))
        let watcher = FakeFolderWatcher()
        let ledger = ImportLedger(paths: paths)
        let (importer, _) = memoImporter(watcher: watcher, ledger: ledger, retryDelay: 0.1)
        try await startEmpty(importer)
        let original = recordings.appending(path: "broken.m4a")
        try Data("not audio".utf8).write(to: original)

        watcher.fire()
        await memoWaitUntil { ledger.isImported(original) }
        await importer.stop()

        #expect(try FileManager.default.contentsOfDirectory(atPath: failed.path) == ["broken.m4a"])
        #expect(try Data(contentsOf: failed.appending(path: "broken.m4a")) == Data("older".utf8))
    }

    // F-5: an undecodable memo whose copy cannot be moved to failed/ is still recorded, so it is not
    // retried on every change, and its copy is still removed.
    @Test func anUndecodableMemoIsRecordedEvenWhenItsCopyCannotBeMoved() async throws {
        try FileManager.default.createDirectory(at: paths.imports, withIntermediateDirectories: true)
        try Data("a file where the folder would go".utf8).write(to: paths.imports.appending(path: "failed"))
        let watcher = FakeFolderWatcher()
        let ledger = ImportLedger(paths: paths)
        let (importer, _) = memoImporter(watcher: watcher, ledger: ledger, retryDelay: 0.1)
        try await startEmpty(importer)
        let original = recordings.appending(path: "broken.m4a")
        try Data("not audio".utf8).write(to: original)

        watcher.fire()
        await memoWaitUntil(timeout: 2) { ledger.isImported(original) }
        await importer.stop()

        #expect(ledger.isImported(original))
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.imports.path).filter { $0.hasSuffix(".m4a") }.isEmpty)
    }

    // Gate repair: an export or sync writes a memo in place under its final name, and an MP4/QuickTime file
    // is undecodable until its index is written last. A scan that takes it mid-write must not record it as
    // undecodable for good: once complete, it is imported.
    @Test func aMemoStillBeingWrittenWhenAScanTakesItIsImportedOnceComplete() async throws {
        let watcher = FakeFolderWatcher()
        let transcriber = ImportFakeTranscriber()
        let ledger = ImportLedger(paths: paths)
        let (importer, _) = memoImporter(watcher: watcher, transcriber: transcriber, ledger: ledger)
        let whole = try Data(contentsOf: try memoM4A(in: fixtures))
        try await startEmpty(importer)
        let memo = recordings.appending(path: "20261017 101500-AB12CD34.m4a")
        try whole.prefix(whole.count / 2).write(to: memo)

        watcher.fire()
        // The scan took the half-written memo: its copy failed to decode and went through failed/.
        await memoWaitUntil { FileManager.default.fileExists(atPath: paths.imports.appending(path: "failed").path) }
        let handle = try FileHandle(forWritingTo: memo)
        try handle.seekToEnd()
        try handle.write(contentsOf: whole.dropFirst(whole.count / 2))
        try handle.close()
        watcher.fire()
        await memoWaitUntil { ledger.isImported(memo) }
        await memoWaitUntil(timeout: 5) { transcriber.calls == 1 }
        await importer.stop()

        #expect(transcriber.calls == 1)
    }

    @Test func aMemoWithNothingStoredIsTriedAgainLater() async throws {
        let watcher = FakeFolderWatcher()
        let transcriber = ImportFailingTranscriber(succeeding: 0)
        let ledger = ImportLedger(paths: paths)
        let (importer, _) = memoImporter(watcher: watcher, transcriber: transcriber, ledger: ledger)
        try await startEmpty(importer)
        let original = try memoM4A()

        watcher.fire()
        await memoWaitUntil { transcriber.calls > 0 }
        await importer.stop()

        #expect(!ledger.isImported(original))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.subpaths(atPath: paths.imports.path)?.filter { $0.hasSuffix(".m4a") } == [])
    }
}
