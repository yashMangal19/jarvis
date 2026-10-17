import AVFoundation
import CoreAudio

/// Meeting mode's room stream: a second AVAudioEngine pinned to the built-in microphone, cut into 30 s,
/// 16 kHz mono chunks labelled `.roomMic`. Separate from `MicSource`, never merged with it. Refuses to
/// start when the built-in mic already is the default input, since `MicSource` records it then.
/// Never requests microphone permission; without it `start` throws `AudioError.permissionDenied`.
public final class RoomMicSource: AudioSourceStream {
    /// Where the default and built-in inputs are, injected so the redundancy rule runs without hardware.
    struct DeviceResolver {
        var defaultInput: () -> AudioDeviceID?
        var builtIn: () -> AudioDeviceID?

        static let system = DeviceResolver(defaultInput: CoreAudioProperty.defaultInputDevice,
                                           builtIn: RoomMicSource.builtInDevice)
    }

    /// Called on a private queue when the stream stops itself after a route change, because the built-in
    /// mic became the default input or can no longer be pinned. `start` works again afterwards.
    public var onStopped: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stoppedHandler }
        set { lock.lock(); stoppedHandler = newValue; lock.unlock() }
    }

    private let resolver: DeviceResolver
    private let queue: DispatchQueue
    private let onQueue = DispatchSpecificKey<Void>()
    private let tap: InputTap
    private let lock = NSLock()
    private var stoppedHandler: (() -> Void)?
    private var chunks = ChunkAssembler(source: .roomMic)
    private var onChunk: ((AudioChunk) -> Void)?

    public convenience init(clock: any TimeSource = SystemClock()) {
        self.init(resolver: .system, clock: clock)
    }

    init(resolver: DeviceResolver, clock: any TimeSource = SystemClock()) {
        self.resolver = resolver
        queue = DispatchQueue(label: "jarvis.room-mic")
        tap = InputTap(queue: queue, clock: clock)
        queue.setSpecific(key: onQueue, value: ())
    }

    deinit {
        // The last release can happen inside a block on `queue`; `queue.sync` there would trap.
        if DispatchQueue.getSpecific(key: onQueue) != nil { tearDown() } else { stop() }
    }

    /// A second call while running does nothing: a second tap on the input bus would crash the engine.
    public func start(onChunk: @escaping (AudioChunk) -> Void) throws {
        let builtIn = try pinnableBuiltIn()
        // Checking status prompts nobody; starting the engine while undetermined would.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw AudioError.permissionDenied }
        try queue.sync {
            guard self.onChunk == nil else { return }
            try startTap(on: builtIn)
            self.onChunk = onChunk  // set only once running, so a failed start can be retried
            tap.onConfigurationChange = { [weak self] in self?.restart() }
        }
    }

    public func stop() {
        queue.sync(execute: tearDown)
    }

    /// The built-in microphone: the first device with built-in transport and at least one input stream.
    public static func builtInDevice() -> AudioDeviceID? {
        CoreAudioProperty.deviceIDs().first { id in
            var transport: UInt32 = 0
            return CoreAudioProperty.read(id, kAudioDevicePropertyTransportType, into: &transport)
                && transport == kAudioDeviceTransportTypeBuiltIn && hasInput(id)
        }
    }

    /// The built-in mic, unless it is missing or already the default input (then it would duplicate the mic).
    private func pinnableBuiltIn() throws -> AudioDeviceID {
        guard let builtIn = resolver.builtIn() else { throw AudioError.noInput }
        guard resolver.defaultInput() != builtIn else { throw AudioError.redundantWithDefaultInput }
        return builtIn
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = CoreAudioProperty.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    // MARK: on `queue`

    private func tearDown() {
        tap.onConfigurationChange = nil
        stopTap()
        onChunk = nil
    }

    private func startTap(on device: AudioDeviceID) throws {
        try tap.start(device: device) { [weak self] samples, time in self?.take(samples, at: time) }
    }

    /// Ends the current chunk too, so no chunk spans a restart gap.
    private func stopTap() {
        tap.stop()
        if let partial = chunks.flush() { onChunk?(partial) }
    }

    /// Re-pins after a configuration change, or stops for good and says so through `onStopped`.
    private func restart() {
        guard onChunk != nil else { return }
        stopTap()
        do {
            try startTap(on: pinnableBuiltIn())
        } catch {
            tearDown()
            onStopped?()
        }
    }

    private func take(_ samples: [Float], at time: Date) {
        guard let onChunk else { return }
        chunks.append(samples, at: time).forEach(onChunk)
    }
}
