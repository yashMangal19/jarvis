import Foundation

/// Imports whatever lands in `~/Jarvis/inbox`: once at start for files already there, then on every change.
public final class InboxImporter {
    private let folder: URL
    private let coordinator: ImportCoordinator
    private let watcher: any FolderWatcher
    private let lock = NSLock()
    private var scanning = false
    private var rescan = false

    public init(paths: JarvisPaths, coordinator: ImportCoordinator, watcher: (any FolderWatcher)? = nil) {
        self.folder = paths.inbox
        self.coordinator = coordinator
        self.watcher = watcher ?? DispatchFolderWatcher(url: paths.inbox)
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watcher.onChange = { [weak self] in self?.scan() }
        try watcher.start()
        scan()
    }

    public func stop() {
        watcher.stop()
        watcher.onChange = nil
    }

    /// One scan at a time, so a file is never imported twice; a change during a scan runs one more.
    private func scan() {
        let begin = lock.withLock { () -> Bool in
            if scanning { rescan = true; return false }
            scanning = true
            return true
        }
        guard begin else { return }
        Task {
            repeat {
                await coordinator.scanAndImport(folder: folder)
            } while lock.withLock({ () -> Bool in
                if rescan { rescan = false; return true }
                scanning = false
                return false
            })
        }
    }
}
