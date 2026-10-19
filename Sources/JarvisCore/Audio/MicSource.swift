import AVFoundation
import AudioToolbox

/// The active microphone as 30 s, 16 kHz mono chunks, plus a tee of 250 ms frames for the wake-word
/// listener. Follows the default input: the engine restarts on `.AVAudioEngineConfigurationChange`; if that
/// finds no usable input, the source stops and says so, and `CaptureDriver` restarts it (J-020).
/// Never requests microphone permission; without it `start` throws `AudioError.permissionDenied`.
public final class MicSource: AudioSourceStream {
    public var onStopped: ((SourceStop) -> Void)?

    /// 250 ms frames of 16 kHz mono samples. Keeps only the newest few if nobody is reading.
    public let frames: AsyncStream<[Float]>

    private let framesOut: AsyncStream<[Float]>.Continuation
    private let queue: DispatchQueue
    private let onQueue = DispatchSpecificKey<Void>()
    private let tap: any AudioTap
    private let authorized: () -> Bool
    private var chunks = ChunkAssembler(source: .mic)
    private var frameCutter = ChunkAssembler(chunkSeconds: 0.25, source: .mic)
    private var onChunk: ((AudioChunk) -> Void)?

    public convenience init(clock: any TimeSource = SystemClock()) {
        self.init(authorized: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
                  makeTap: { InputTap(queue: $0, clock: clock) })
    }

    /// `makeTap` receives the queue every tap member is called on.
    init(authorized: @escaping () -> Bool, makeTap: (DispatchQueue) -> any AudioTap) {
        (frames, framesOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        queue = DispatchQueue(label: "jarvis.mic")
        tap = makeTap(queue)
        self.authorized = authorized
        queue.setSpecific(key: onQueue, value: ())
    }

    deinit {
        // The last release can happen inside a block on `queue`; `queue.sync` there would trap.
        if DispatchQueue.getSpecific(key: onQueue) != nil { tearDown() } else { stop() }
        framesOut.finish()
    }

    /// A second call while running does nothing: a second tap on the input bus would crash the engine.
    public func start(onChunk: @escaping (AudioChunk) -> Void) throws {
        // Checking status prompts nobody; starting the engine while undetermined would.
        guard authorized() else { throw AudioError.permissionDenied }
        try queue.sync {
            guard self.onChunk == nil else { return }
            try startTap()
            self.onChunk = onChunk  // set only once running, so a failed start can be retried
            tap.onConfigurationChange = { [weak self] in self?.restart() }
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

    // MARK: on `queue`

    private func tearDown() {
        tap.onConfigurationChange = nil
        stopTap()
        onChunk = nil
    }

    private func startTap() throws {
        try tap.start(device: nil) { [weak self] samples, time in self?.take(samples, at: time) }
    }

    /// Ends the current chunk too, so no chunk spans a restart gap.
    private func stopTap() {
        tap.stop()
        if let partial = chunks.flush() { onChunk?(partial) }
        _ = frameCutter.flush()
    }

    /// A device mid-switch has no usable input for a moment: then the source stops and says so.
    private func restart() {
        guard onChunk != nil else { return }
        stopTap()
        do { try startTap() } catch {
            tearDown()
            onStopped?(.failed)
        }
    }

    private func take(_ samples: [Float], at time: Date) {
        guard let onChunk else { return }
        chunks.append(samples, at: time).forEach(onChunk)
        frameCutter.append(samples, at: time).forEach { framesOut.yield($0.samples) }
    }
}

/// What `MicSource` needs from an input tap: `InputTap`, or a fake in tests. Call every member on the
/// owner's queue; `onConfigurationChange` is called there too.
protocol AudioTap: AnyObject {
    var onConfigurationChange: (() -> Void)? { get set }
    func start(device: AudioDeviceID?, onSamples: @escaping (_ samples: [Float], _ heardAt: Date) -> Void) throws
    func stop()
}

extension InputTap: AudioTap {}

/// The AVAudioEngine input tap both microphone streams share: 16 kHz mono samples delivered on the
/// owner's queue, and configuration changes forwarded there. Call every member on that queue.
final class InputTap {
    private static let sampleRate = 16_000.0
    /// Called on the owner's queue after `.AVAudioEngineConfigurationChange`; restart from here.
    var onConfigurationChange: (() -> Void)?

    private let engine = AVAudioEngine()
    private let queue: DispatchQueue
    private let clock: any TimeSource
    private var observer: NSObjectProtocol?
    /// Bumped on every stop, so samples an old tap queued are dropped after a restart.
    private var generation = 0

    init(queue: DispatchQueue, clock: any TimeSource) {
        self.queue = queue
        self.clock = clock
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, queue] _ in
            // Apple: never tear the engine down inside this handler; hop to the owner's queue.
            queue.async { self?.onConfigurationChange?() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Installs the tap and starts the engine. `device` pins the input; `nil` follows the default input.
    func start(device: AudioDeviceID? = nil, onSamples: @escaping (_ samples: [Float], _ heardAt: Date) -> Void) throws {
        let input = engine.inputNode
        if var device {
            guard let unit = input.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
            else { throw AudioError.noInput }
        }
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw AudioError.noInput }
        converter.downmix = true  // mix a multi-channel mic (the built-in one is an array) to mono
        let generation = generation
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self, let samples = Self.convert(buffer, with: converter, to: outFormat) else { return }
            let heardAt = self.clock.now.addingTimeInterval(-Double(samples.count) / Self.sampleRate)
            self.queue.async { [weak self] in
                guard let self, generation == self.generation else { return }
                onSamples(samples, heardAt)
            }
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        generation += 1
    }

    /// One tap buffer at 16 kHz mono; the converter keeps its resampler state between buffers.
    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> [Float]? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}
