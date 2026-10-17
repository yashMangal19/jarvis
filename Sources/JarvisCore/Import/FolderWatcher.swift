import Foundation

/// Calls `onChange` when a folder's contents change.
public protocol FolderWatcher: AnyObject {
    var onChange: (() -> Void)? { get set }
    func start() throws
    func stop()
}

/// Watches one directory for writes (a file added, removed or renamed in it) and calls `onChange`
/// once things have been quiet for `debounce` seconds, so a burst of copies is one call.
public final class DispatchFolderWatcher: FolderWatcher {
    public var onChange: (() -> Void)?
    private let url: URL
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "jarvis.folder-watcher")
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    public init(url: URL, debounce: TimeInterval = 2) {
        self.url = url
        self.debounce = debounce
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
        queue.sync { pending?.cancel(); pending = nil }
    }

    /// On `queue`.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
