import Foundation

/// Calls `onChange` when a folder's contents change.
public protocol FolderWatcher: AnyObject {
    var onChange: (() -> Void)? { get set }
    func start() throws
    func stop()
}

/// Watches one directory for writes (a file added, removed or renamed in it) and calls `onChange`
/// once things have been quiet for `debounce` seconds, so a burst of copies is one call.
/// A file growing in place is not a write to the directory, so it raises no call.
///
/// `onChange` runs on the watcher's own serial queue: keep it short and hand real work elsewhere.
/// `stop()` and `start()` may be called from inside it.
public final class DispatchFolderWatcher: FolderWatcher {
    public var onChange: (() -> Void)?
    private let url: URL
    private let debounce: TimeInterval
    private let scheduler: any Scheduler
    private let queue = DispatchQueue(label: "jarvis.folder-watcher")
    private let onQueue = DispatchSpecificKey<Void>()
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    public init(url: URL, debounce: TimeInterval = 2, scheduler: any Scheduler = SystemScheduler()) {
        self.url = url
        self.debounce = debounce
        self.scheduler = scheduler
        queue.setSpecific(key: onQueue, value: ())
    }

    public func start() throws {
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]) }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        let cancel = { self.pending?.cancel(); self.pending = nil }
        if DispatchQueue.getSpecific(key: onQueue) != nil { cancel() } else { queue.sync(execute: cancel) }
    }

    /// On `queue`.
    private func schedule() {
        pending?.cancel()
        pending = scheduler.after(debounce, on: queue) { [weak self] in self?.onChange?() }
    }
}
