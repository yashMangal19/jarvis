import Foundation

/// Runs `scan` one at a time, so a file is never imported twice; a request during a scan runs one more
/// after it. A scan that leaves files behind (`scan` returns how many) schedules another `retryDelay`
/// seconds later, up to `maxRetries` in a row; `folderChanged()` resets the count.
/// Shared by `InboxImporter` and `VoiceMemosImporter`.
final class ScanScheduler {
    private let retryDelay: TimeInterval
    private let maxRetries: Int
    private let scan: () async -> Int
    private let scheduler: any Scheduler
    private let lock = NSLock()
    private var scanTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var rescan = false
    private var retries = 0
    private var stopped = true

    init(retryDelay: TimeInterval, maxRetries: Int, scheduler: any Scheduler = SystemScheduler(),
         scan: @escaping () async -> Int) {
        self.retryDelay = retryDelay
        self.maxRetries = maxRetries
        self.scheduler = scheduler
        self.scan = scan
    }

    /// No scan is running or queued to run. For tests: `start()` and `folderChanged()` queue one at once.
    var isIdle: Bool { lock.withLock { scanTask == nil } }

    /// Allows scans (again, after `stop()`) and runs one now.
    func start() {
        lock.withLock { stopped = false }
        request()
    }

    func folderChanged() {
        lock.withLock { retries = 0 }
        request()
    }

    /// Stops retrying, cancels the scan in flight and returns once it has ended.
    /// A file already being transcribed finishes; no later file is started.
    func stop() async {
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

    private func request() {
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
            let waiting = await scan()
            again = lock.withLock {
                if Task.isCancelled || stopped { return false }
                if rescan { rescan = false; return true }
                scanTask = nil
                if waiting == 0 { retries = 0 } else if retries < maxRetries {
                    retries += 1
                    let delay = retryDelay, scheduler = scheduler
                    retryTask = Task { [weak self] in
                        try? await scheduler.sleep(for: delay)
                        if !Task.isCancelled { self?.request() }
                    }
                }
                return false
            }
        }
    }

    /// The files of `look()` whose size is non-zero and unchanged across two looks `delay` seconds
    /// apart, by path, so a file still being copied in is left for a later scan.
    static func settledFiles(after delay: TimeInterval, scheduler: any Scheduler = SystemScheduler(),
                             _ look: () -> [URL: Int]) async -> [URL] {
        let before = look()
        try? await scheduler.sleep(for: delay)
        return look().filter { $0.value > 0 && before[$0.key] == $0.value }.keys.sorted { $0.path < $1.path }
    }

    /// The size of every file in `folder` that `matches`; a size that cannot be read is 0.
    static func sizes(in folder: URL, matching matches: (URL) -> Bool) -> [URL: Int] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)) ?? []
        var sizes: [URL: Int] = [:]
        for url in files where matches(url) {
            sizes[url] = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return sizes
    }
}
