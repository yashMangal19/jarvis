import AVFAudio
import Foundation
import Testing
import JarvisCore

@Suite struct VoiceMemosImporterTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-memos-\(UUID().uuidString)")
    let recordedAt = Date(timeIntervalSince1970: 1_792_000_000)

    var paths: JarvisPaths { JarvisPaths(root: root) }
    /// Stands in for the Voice Memos "Recordings" folder.
    var recordings: URL { root.appending(path: "VoiceMemos/Recordings") }

    /// A `seconds`-long tone at speech level in the fake Recordings folder, dated `recordedAt`.
    func memoM4A(seconds: Double = 3, name: String = "20261017 101500-AB12CD34.m4a") throws -> URL {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let url = recordings.appending(path: name)
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
                      ledger: ImportLedger? = nil) -> (VoiceMemosImporter, TranscriptStore) {
        let store = TranscriptStore(paths: paths)
        let coordinator = ImportCoordinator(pipeline: CapturePipeline(transcriber: transcriber, store: store),
                                            onImported: { _ in })
        let access = access ?? .readable(recordings)
        let importer = VoiceMemosImporter(locator: { access }, watcherFactory: { _ in watcher },
                                          coordinator: coordinator, ledger: ledger ?? ImportLedger(paths: paths),
                                          paths: paths, settleDelay: 0.05, retryDelay: 60)
        return (importer, store)
    }

    func memoLines(_ store: TranscriptStore) throws -> [TranscriptLine] {
        try store.lines(in: DateInterval(start: .distantPast, end: .distantFuture))
    }

    func memoWaitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test func importsACopyAndLeavesTheOriginalUntouched() async throws {
        let original = try memoM4A()
        let bytes = try Data(contentsOf: original)
        // AVAudioFile stamps an m4a with its write time as creation metadata; a real memo carries its recording time.
        let recorded = await RecordingDate.of(original)
        let modified = try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let ledger = ImportLedger(paths: paths)
        let (importer, store) = memoImporter(ledger: ledger)

        try importer.start()
        await memoWaitUntil { ledger.isImported(original) }
        await importer.stop()

        #expect(ledger.isImported(original))
        #expect(try Data(contentsOf: original) == bytes)
        #expect(try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        let lines = try memoLines(store)
        #expect(lines.count == 1)
        #expect(lines.first?.time == TranscriptLine(time: recorded, label: .me, text: "").time)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.imports.path).filter { $0.hasSuffix(".m4a") }.isEmpty)
    }

    @Test func aSecondChangeImportsNothing() async throws {
        let original = try memoM4A()
        let watcher = FakeFolderWatcher()
        let transcriber = ImportFakeTranscriber()
        let ledger = ImportLedger(paths: paths)
        let (importer, _) = memoImporter(watcher: watcher, transcriber: transcriber, ledger: ledger)

        try importer.start()
        await memoWaitUntil { ledger.isImported(original) }
        watcher.fire()
        try await Task.sleep(nanoseconds: 500_000_000)
        await importer.stop()

        #expect(transcriber.calls == 1)
        #expect(ImportLedger(paths: paths).isImported(original))
    }

    @Test func anUnreadableFolderAsksForFullDiskAccess() async throws {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: recordings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recordings.path) }
        let missing = root.appending(path: "nowhere/Recordings")

        #expect(VoiceMemosLocator.probe([missing, recordings]) == .unreadable(recordings))
        #expect(VoiceMemosLocator.probe([missing]) == .absent)

        let (importer, _) = memoImporter(access: .unreadable(recordings))
        try importer.start()
        #expect(importer.needsFullDiskAccess)
        await importer.stop()
    }

    @Test func probeTakesTheFirstFolderThatExists() throws {
        let other = root.appending(path: "Legacy/Recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        #expect(VoiceMemosLocator.probe([root.appending(path: "nowhere"), other, recordings]) == .readable(other))
    }

    @Test func anUndecodableMemoIsRecordedAndLeavesNoCopy() async throws {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let original = recordings.appending(path: "broken.m4a")
        try Data("not audio".utf8).write(to: original)
        let ledger = ImportLedger(paths: paths)
        let (importer, _) = memoImporter(ledger: ledger)

        try importer.start()
        await memoWaitUntil { ledger.isImported(original) }
        await importer.stop()

        #expect(ledger.isImported(original))
        #expect(try Data(contentsOf: original) == Data("not audio".utf8))
        #expect(FileManager.default.subpaths(atPath: paths.imports.path)?.filter { $0.hasSuffix(".m4a") } == [])
    }

    @Test func aMemoWithNothingStoredIsTriedAgainLater() async throws {
        let original = try memoM4A()
        let transcriber = ImportFailingTranscriber(succeeding: 0)
        let ledger = ImportLedger(paths: paths)
        let (importer, _) = memoImporter(transcriber: transcriber, ledger: ledger)

        try importer.start()
        await memoWaitUntil { transcriber.calls > 0 }
        await importer.stop()

        #expect(!ledger.isImported(original))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.subpaths(atPath: paths.imports.path)?.filter { $0.hasSuffix(".m4a") } == [])
    }
}
