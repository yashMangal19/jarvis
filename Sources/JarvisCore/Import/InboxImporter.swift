import Foundation

/// Imports whatever lands in `~/Jarvis/inbox`: once at start for files already there, then on every change.
public final class InboxImporter {
    private let folder: URL
    private let coordinator: ImportCoordinator
    private let watcher: any FolderWatcher
    private let retryDelay: TimeInterval
    private let maxRetries: Int
    private let lock = NSLock()
    private var scanTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var rescan = false
    private var retries = 0
    private var stopped = false

    /// A scan that leaves a recording behind (still copying, or kept after a failure) schedules another
    /// `retryDelay` seconds later, up to `maxRetries` in a row; a folder change resets the count.
    public init(paths: JarvisPaths, coordinator: ImportCoordinator, watcher: (any FolderWatcher)? = nil,
                retryDelay: TimeInterval = 5, maxRetries: Int = 12) {
        self.folder = paths.inbox
        self.coordinator = coordinator
        self.watcher = watcher ?? DispatchFolderWatcher(url: paths.inbox)
        self.retryDelay = retryDelay
        self.maxRetries = maxRetries
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        lock.withLock { stopped = false }
        watcher.onChange = { [weak self] in self?.folderChanged() }
        try watcher.start()
        scan()
    }

    /// Stops watching and retrying, cancels the scan in flight and returns once it has ended.
    /// A file already being transcribed finishes; no later file is started.
    public func stop() async {
        watcher.stop()
        watcher.onChange = nil
        let scan = lock.withLock { () -> Task<Void, Never>? in
            stopped = true
            retryTask?.cancel()
            retryTask = nil
            return scanTask
        }
        scan?.cancel()
        await scan?.value
        lock.withLock { scanTask = nil; rescan = false }
    }

    private func folderChanged() {
        lock.withLock { retries = 0 }
        scan()
    }

    /// One scan at a time, so a file is never imported twice; a change during a scan runs one more.
    private func scan() {
        lock.withLock {
            guard !stopped else { return }
            if scanTask != nil { rescan = true; return }
            retryTask?.cancel()
            retryTask = nil
            scanTask = Task { await self.runScans() }
        }
    }

    private func runScans() async {
        var again = true
        while again {
            let waiting = await coordinator.scanAndImport(folder: folder).waiting
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
}
