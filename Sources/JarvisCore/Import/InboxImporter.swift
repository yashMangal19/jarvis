import Foundation

/// Imports whatever lands in the data home's `inbox` folder: once at start for files already there, then on every change.
public final class InboxImporter {
    private let folder: URL
    private let watcher: any FolderWatcher
    private let scheduler: ScanScheduler

    /// A scan that leaves a recording behind (still copying, or kept after a failure) schedules another
    /// `retryDelay` seconds later, up to `maxRetries` in a row; a folder change resets the count.
    public init(paths: JarvisPaths, coordinator: ImportCoordinator, watcher: (any FolderWatcher)? = nil,
                retryDelay: TimeInterval = 5, maxRetries: Int = 12) {
        let folder = paths.inbox
        self.folder = folder
        self.watcher = watcher ?? DispatchFolderWatcher(url: folder)
        scheduler = ScanScheduler(retryDelay: retryDelay, maxRetries: maxRetries) {
            await coordinator.scanAndImport(folder: folder).waiting
        }
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watcher.onChange = { [weak self] in self?.scheduler.folderChanged() }
        try watcher.start()
        scheduler.start()
    }

    /// Stops watching and retrying, cancels the scan in flight and returns once it has ended.
    /// A file already being transcribed finishes; no later file is started.
    public func stop() async {
        watcher.stop()
        watcher.onChange = nil
        await scheduler.stop()
    }
}
