import Foundation

/// Imports Voice Memos as they sync to the Mac: each new memo is copied into `~/Jarvis/imports`,
/// the copy is transcribed and deleted, and the memo is recorded in the ledger so it is imported once.
/// Originals are only ever listed and read by the copy; never opened for writing, moved or deleted.
public final class VoiceMemosImporter: ObservableObject {
    /// True when the recordings folder exists but cannot be read without Full Disk Access.
    @Published public private(set) var needsFullDiskAccess = false

    private let locator: () -> VoiceMemosAccess
    private let watcherFactory: (URL) -> any FolderWatcher
    private let coordinator: ImportCoordinator
    private let ledger: ImportLedger
    private let imports: URL
    private let settleDelay: TimeInterval
    private let retryDelay: TimeInterval
    private let maxRetries: Int
    private let lock = NSLock()
    private var watcher: (any FolderWatcher)?
    private var folder: URL?
    private var scanTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var rescan = false
    private var retries = 0
    private var stopped = false

    /// A memo is taken once its size is unchanged across two looks `settleDelay` seconds apart.
    /// A scan that leaves a memo behind (still syncing, or failed) schedules another `retryDelay`
    /// seconds later, up to `maxRetries` in a row; a folder change resets the count.
    public init(locator: @escaping () -> VoiceMemosAccess = { VoiceMemosLocator.probe() },
                watcherFactory: @escaping (URL) -> any FolderWatcher = { DispatchFolderWatcher(url: $0) },
                coordinator: ImportCoordinator, ledger: ImportLedger, paths: JarvisPaths,
                settleDelay: TimeInterval = 2, retryDelay: TimeInterval = 5, maxRetries: Int = 12) {
        self.locator = locator
        self.watcherFactory = watcherFactory
        self.coordinator = coordinator
        self.ledger = ledger
        self.imports = paths.imports
        self.settleDelay = settleDelay
        self.retryDelay = retryDelay
        self.maxRetries = maxRetries
    }

    /// Probes the folder and, when it is readable, imports what is new now and on every change.
    /// Nothing re-probes on its own: call again after Full Disk Access is granted or a first memo syncs.
    public func start() throws {
        let access = locator()
        needsFullDiskAccess = if case .unreadable = access { true } else { false }
        guard case .readable(let folder) = access else { return }
        let watcher = watcherFactory(folder)
        lock.withLock {
            self.watcher?.stop()
            self.watcher = watcher
            self.folder = folder
            stopped = false
        }
        watcher.onChange = { [weak self] in self?.folderChanged() }
        try watcher.start()
        scan()
    }

    /// Stops watching and retrying, cancels the scan in flight and returns once it has ended.
    public func stop() async {
        let (watcher, scan) = lock.withLock { () -> ((any FolderWatcher)?, Task<Void, Never>?) in
            stopped = true
            retryTask?.cancel()
            retryTask = nil
            return (self.watcher, scanTask)
        }
        watcher?.stop()
        watcher?.onChange = nil
        scan?.cancel()
        await scan?.value
        lock.withLock { scanTask = nil; rescan = false }
    }

    private func folderChanged() {
        lock.withLock { retries = 0 }
        scan()
    }

    /// One scan at a time, so a memo is never imported twice; a change during a scan runs one more.
    /// Same scheduling as `InboxImporter`.
    private func scan() {
        lock.withLock {
            guard !stopped, let folder else { return }
            if scanTask != nil { rescan = true; return }
            retryTask?.cancel()
            retryTask = nil
            scanTask = Task { await self.runScans(folder) }
        }
    }

    private func runScans(_ folder: URL) async {
        var again = true
        while again {
            let waiting = await importNew(from: folder)
            again = lock.withLock {
                if Task.isCancelled || stopped { return false }
                if rescan { rescan = false; return true }
                scanTask = nil
                if waiting == 0 { retries = 0 } else if retries < maxRetries {
                    retries += 1
                    let delay = UInt64(retryDelay * 1_000_000_000)
                    retryTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: delay)
                        if !Task.isCancelled { self?.scan() }
                    }
                }
                return false
            }
        }
    }

    /// Imports every new, size-stable memo; returns how many new memos are left for a later scan.
    private func importNew(from folder: URL) async -> Int {
        let before = newMemos(in: folder)
        try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        let after = newMemos(in: folder)
        var waiting = 0
        for (original, size) in after.sorted(by: { $0.key.path < $1.key.path }) {
            if Task.isCancelled { break }
            if size > 0, before[original] == size, await importCopy(of: original) { continue }
            waiting += 1
        }
        return waiting
    }

    /// True once `original` is done with (imported, or found undecodable); false to try again later.
    private func importCopy(of original: URL) async -> Bool {
        let fileManager = FileManager.default
        let copy = imports.appending(path: original.lastPathComponent)
        do {
            try fileManager.createDirectory(at: imports, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: copy) // left by an earlier failed try
            try fileManager.copyItem(at: original, to: copy)
        } catch {
            return false
        }
        do {
            try await coordinator.importFile(copy)
        } catch ImportError.notDeleted {
            try? fileManager.removeItem(at: copy) // lines are stored; only the copy's delete failed
        } catch {
            if fileManager.fileExists(atPath: copy.path) {
                try? fileManager.removeItem(at: copy) // nothing stored: the original is tried again
                return false
            }
            // The copy is gone: a later chunk failed after lines were stored (it was deleted), or it
            // could not be decoded and the coordinator moved it to `failed/`. The original stays in
            // Voice Memos, so Jarvis's failed copy is not kept.
            try? fileManager.removeItem(at: imports.appending(path: "failed").appending(path: copy.lastPathComponent))
        }
        // A ledger that cannot be written still holds the memo in memory; it re-imports after a relaunch.
        try? ledger.record(original)
        return true
    }

    private func newMemos(in folder: URL) -> [URL: Int] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)) ?? []
        var sizes: [URL: Int] = [:]
        for url in files where url.pathExtension.lowercased() == "m4a" && !ledger.isImported(url) {
            sizes[url] = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return sizes
    }
}
