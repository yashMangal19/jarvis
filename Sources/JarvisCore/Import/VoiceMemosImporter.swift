import Foundation

/// Imports Voice Memos as they sync to the Mac: each new memo is copied into the data home's `imports` folder,
/// the copy is transcribed and deleted, and the memo is recorded in the ledger so it is imported once.
/// Originals are only ever listed and read by the copy; never opened for writing, moved or deleted.
///
/// The first time the folder is readable, the memos already in it are recorded as a baseline and not
/// imported (backlog decision A); only memos that appear afterwards are. A folder absent at first
/// start takes an empty baseline, so the memo that later creates it is imported.
public final class VoiceMemosImporter: ObservableObject {
    /// True when the recordings folder exists but cannot be read without Full Disk Access.
    @Published public private(set) var needsFullDiskAccess = false

    /// `.m4a`, and the QuickTime-container `.qta` recent Voice Memos versions also write (AVAudioFile
    /// decodes a single-track one; a real synced `.qta` is unverified until one reaches this Mac).
    static let memoExtensions: Set<String> = ["m4a", "qta"]

    private let locator: () -> VoiceMemosAccess
    private let watcherFactory: (URL) -> any FolderWatcher
    private let coordinator: ImportCoordinator
    private let ledger: ImportLedger
    private let imports: URL
    private let settleDelay: TimeInterval
    private let lock = NSLock()
    private var watcher: (any FolderWatcher)?
    private var folder: URL?
    /// Memos whose copy did not decode, as they were then and when first seen so; recorded only if a scan
    /// at least `retryDelay` later finds them unchanged.
    private var undecodable: [URL: (stamp: FileStamp, since: Date)] = [:]
    private let retryDelay: TimeInterval
    private let clock: any Scheduler
    /// Set once at the end of `init`; it calls back into `self`, so it cannot be built before.
    private var scheduler: ScanScheduler!

    /// A memo is taken once its size is unchanged across two looks `settleDelay` seconds apart.
    /// A scan that leaves a memo behind (still syncing, or failed) schedules another `retryDelay`
    /// seconds later, up to `maxRetries` in a row; a folder change resets the count.
    public init(locator: @escaping () -> VoiceMemosAccess = { VoiceMemosLocator.probe() },
                watcherFactory: @escaping (URL) -> any FolderWatcher = { DispatchFolderWatcher(url: $0) },
                coordinator: ImportCoordinator, ledger: ImportLedger, paths: JarvisPaths,
                settleDelay: TimeInterval = 2, retryDelay: TimeInterval = 5, maxRetries: Int = 12,
                scheduler clock: any Scheduler = SystemScheduler()) {
        self.locator = locator
        self.watcherFactory = watcherFactory
        self.coordinator = coordinator
        self.ledger = ledger
        self.imports = paths.imports
        self.settleDelay = settleDelay
        self.retryDelay = retryDelay
        self.clock = clock
        scheduler = ScanScheduler(retryDelay: retryDelay, maxRetries: maxRetries, scheduler: clock) { [weak self] in
            await self?.importNew() ?? 0
        }
    }

    /// Probes the folder and, when it is readable, imports what is new now and on every change.
    /// Nothing re-probes on its own: call again after Full Disk Access is granted or a first memo syncs.
    /// `needsFullDiskAccess` changes on the main actor, so a SwiftUI view can observe it.
    public func start() async throws {
        let access = locator()
        let needsAccess = if case .unreadable = access { true } else { false }
        await MainActor.run { needsFullDiskAccess = needsAccess }
        // No folder yet means no memo has synced: the baseline is empty, so the first one imports.
        // An unreadable folder may hold memos from before access was granted, so it waits for a read.
        if case .absent = access, !ledger.hasBaseline { try? ledger.recordBaseline([]) }
        guard case .readable(let folder) = access else { return }
        if !ledger.hasBaseline {
            // A ledger that cannot be written keeps the baseline in memory; a relaunch takes it again.
            try? ledger.recordBaseline(Array(memos(in: folder).keys))
        }
        let watcher = watcherFactory(folder)
        lock.withLock {
            self.watcher?.stop()
            self.watcher = watcher
            self.folder = folder
        }
        watcher.onChange = { [weak self] in self?.scheduler.folderChanged() }
        try watcher.start()
        scheduler.start()
    }

    /// No scan is running or queued (tests wait on it after `start()`).
    var scanIsIdle: Bool { scheduler.isIdle }

    /// Stops watching and retrying, cancels the scan in flight and returns once it has ended.
    public func stop() async {
        let watcher = lock.withLock { self.watcher }
        watcher?.stop()
        watcher?.onChange = nil
        await scheduler.stop()
    }

    /// Imports every new, size-stable memo; returns how many new memos are left for a later scan.
    private func importNew() async -> Int {
        guard let folder = lock.withLock({ self.folder }) else { return 0 }
        for original in await ScanScheduler.settledFiles(after: settleDelay, scheduler: clock, { newMemos(in: folder) }) {
            if Task.isCancelled { break }
            await importCopy(of: original)
        }
        return newMemos(in: folder).count
    }

    /// Records `original` once it is done with: imported (for good), or undecodable (for this version only,
    /// DEC-48). Leaves it for a later scan when nothing of it was stored.
    private func importCopy(of original: URL) async {
        let fileManager = FileManager.default
        let copy = imports.appending(path: original.lastPathComponent)
        let stamp = FileStamp(original)
        do {
            try fileManager.createDirectory(at: imports, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: copy) // left by an earlier failed try
            try fileManager.copyItem(at: original, to: copy)
        } catch {
            return
        }
        do {
            try await coordinator.importFile(copy)
        } catch ImportError.notDeleted {
            try? fileManager.removeItem(at: copy) // lines are stored; only the copy's delete failed
        } catch ImportError.undecodable(let movedTo, _) {
            // The original stays in Voice Memos, so Jarvis's failed copy is not kept, wherever it is.
            try? fileManager.removeItem(at: movedTo ?? copy)
            // An export or sync writes a memo in place, and an MP4/QuickTime file does not decode until its
            // index is written last, so one still being written looks broken. The verdict is on this version
            // only (DEC-48): if the memo changes later, it is a candidate again, so no stall can lose it. Until
            // then, a memo still changing keeps being retried; it is set aside once a scan at least `retryDelay`
            // after the first finds it unchanged. That gap is for promptness, not correctness (J-011).
            let settled = lock.withLock { () -> Bool in
                let now = clock.now
                if let seen = undecodable[original], seen.stamp == stamp {
                    return now.timeIntervalSince(seen.since) >= retryDelay
                }
                undecodable[original] = (stamp, now)
                return false
            }
            guard settled else { return }
            do { try ledger.recordUndecodable(original, as: stamp) } catch {
                Log.imports.error("Voice Memos ledger not written, held in memory: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
            }
            Log.imports.notice("A Voice Memo doesn't decode yet; it is tried again when it changes")
            return
        } catch {
            if fileManager.fileExists(atPath: copy.path) {
                try? fileManager.removeItem(at: copy) // nothing stored: the original is tried again
                return
            }
            // The copy is gone: a later chunk failed after lines were stored, and it was deleted.
        }
        // A ledger that cannot be written still holds the memo in memory; it re-imports after a relaunch.
        do { try ledger.record(original) } catch {
            Log.imports.error("Voice Memos ledger not written, held in memory: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
    }

    private func memos(in folder: URL) -> [URL: Int] {
        ScanScheduler.sizes(in: folder) { Self.memoExtensions.contains($0.pathExtension.lowercased()) }
    }

    private func newMemos(in folder: URL) -> [URL: Int] {
        memos(in: folder).filter { !ledger.isImported($0.key) }
    }
}
