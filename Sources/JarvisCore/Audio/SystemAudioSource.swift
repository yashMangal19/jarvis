import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// The Mac's system audio (the far side of a call) via ScreenCaptureKit, as 30 s, 16 kHz mono chunks
/// labelled `.systemAudio`. Its own stream, never merged with the mic's. Jarvis's own speech is left out
/// (`excludesCurrentProcessAudio`, D-8). Never requests Screen Recording; without it `start` throws
/// `AudioError.permissionDenied`.
public final class SystemAudioSource: NSObject, AudioSourceStream, SCStreamOutput, SCStreamDelegate {
    /// Screen Recording is granted. Checking prompts nobody; the app asks (T-25).
    public static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    private static let sampleRate = 16_000
    /// How long `start` waits on ScreenCaptureKit before giving up.
    private static let setupTimeout: DispatchTimeInterval = .seconds(10)
    private let clock: any TimeSource
    private let queue = DispatchQueue(label: "jarvis.system-audio")
    private let onQueue = DispatchSpecificKey<Void>()
    private var chunks = ChunkAssembler(source: .systemAudio)
    private var onChunk: ((AudioChunk) -> Void)?
    /// The running stream. Buffers from any other (a stopped one) are dropped, so none spans a restart.
    private var stream: SCStream?
    public var onStopped: ((SourceStop) -> Void)?

    public init(clock: any TimeSource = SystemClock()) {
        self.clock = clock
        super.init()
        queue.setSpecific(key: onQueue, value: ())
    }

    deinit {
        // The last release can happen inside a block on `queue`; `queue.sync` there would trap.
        if DispatchQueue.getSpecific(key: onQueue) != nil { tearDown() } else { stop() }
    }

    /// Blocks until capture runs or fails. A second call while running does nothing.
    public func start(onChunk: @escaping (AudioChunk) -> Void) throws {
        guard Self.isAuthorized else { throw AudioError.permissionDenied }
        try queue.sync {
            guard self.onChunk == nil else { return }
            let stream = try makeStream()
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            do {
                try Self.wait({ done in stream.startCapture { done($0.map { .failure($0) } ?? .success(())) } },
                              late: { if case .success = $0 { stream.stopCapture() } })
            } catch {
                // Never stored in `self.stream`, so nothing else would ever stop it.
                try? stream.removeStreamOutput(self, type: .audio)
                stream.stopCapture()
                throw error
            }
            self.stream = stream
            self.onChunk = onChunk  // set only once running, so a failed start can be retried
        }
    }

    public func stop() {
        queue.sync(execute: tearDown)
    }

    /// Hands over the partial chunk now (`ChunkAssembler.flush`); the next chunk starts with the next
    /// samples. A no-op while stopped (DEC-24).
    public func cut() {
        queue.sync { if let partial = chunks.flush() { onChunk?(partial) } }
    }

    // MARK: SCStreamOutput on `queue` (its `sampleHandlerQueue`); SCStreamDelegate on a ScreenCaptureKit queue

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio, stream === self.stream, let onChunk,
              let samples = Self.samples(in: sampleBuffer) else { return }
        let heardAt = clock.now.addingTimeInterval(-Double(samples.count) / Double(Self.sampleRate))
        chunks.append(samples, at: heardAt).forEach(onChunk)
    }

    /// Capture ended without `stop` (permission revoked, display gone): hand over the partial chunk and say so,
    /// so `CaptureDriver` restarts it (J-020). Before J-020 it stopped here silently.
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async { [weak self] in
            guard let self, stream === self.stream else { return }
            self.tearDown()
            self.onStopped?(.failed)
        }
    }

    // MARK: on `queue`

    private func tearDown() {
        if let stream {
            try? stream.removeStreamOutput(self, type: .audio)
            stream.stopCapture()
        }
        stream = nil
        if let partial = chunks.flush() { onChunk?(partial) }
        onChunk = nil
    }

    /// Audio-only in effect: a display filter is required, so the video is 1×1 at 1 fps and unread.
    private func makeStream() throws -> SCStream {
        let content: SCShareableContent = try Self.wait { done in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                done(content.map { .success($0) } ?? .failure(error ?? AudioError.noInput))
            }
        }
        guard let display = content.displays.first else { throw AudioError.noInput }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Self.sampleRate
        config.channelCount = 1
        config.width = 1
        config.height = 1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        return SCStream(filter: filter, configuration: config, delegate: self)
    }

    /// Waits for one ScreenCaptureKit completion handler; never called on the handler's queue. Past
    /// `timeout` it throws `.noInput`, and a result that arrives later goes to `late` instead.
    static func wait<T>(timeout: DispatchTimeInterval = setupTimeout,
                        _ call: (@escaping (Result<T, any Error>) -> Void) -> Void,
                        late: @escaping (Result<T, any Error>) -> Void = { _ in }) throws -> T {
        let box = CompletionBox(late: late)
        call(box.complete)
        guard let result = box.wait(timeout) else { throw AudioError.noInput }
        return try result.get()
    }

    /// The buffer's samples, if it is the mono 16 kHz float audio the configuration asked for.
    private static func samples(in buffer: CMSampleBuffer) -> [Float]? {
        guard let format = buffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame == 1,
              format.mSampleRate == Double(sampleRate) else { return nil }
        return try? buffer.withAudioBufferList { list, _ in
            guard let first = list.first, let data = first.mData else { return [] }
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                             count: Int(first.mDataByteSize) / MemoryLayout<Float>.size))
        }
    }
}

/// One completion result handed from a ScreenCaptureKit queue to the waiting thread, under a lock.
private final class CompletionBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private let late: (Result<T, any Error>) -> Void
    private var result: Result<T, any Error>?
    private var abandoned = false

    init(late: @escaping (Result<T, any Error>) -> Void) {
        self.late = late
    }

    func complete(_ result: Result<T, any Error>) {
        lock.lock()
        guard !abandoned else { lock.unlock(); late(result); return }
        self.result = result
        lock.unlock()
        arrived.signal()
    }

    /// The result, or `nil` once `timeout` passes with none; every later result then goes to `late`.
    func wait(_ timeout: DispatchTimeInterval) -> Result<T, any Error>? {
        let inTime = arrived.wait(timeout: .now() + timeout) == .success
        lock.lock()
        defer { lock.unlock() }
        if !inTime, result == nil { abandoned = true }
        return result
    }
}
