import AVFoundation
import AudioToolbox
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

        static let system = DeviceResolver(defaultInput: RoomMicSource.defaultInputDevice,
                                           builtIn: RoomMicSource.builtInDevice)
    }

    private static let sampleRate = 16_000.0
    private let resolver: DeviceResolver
    private let clock: any TimeSource
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "jarvis.room-mic")
    private let onQueue = DispatchSpecificKey<Void>()
    private var chunks = ChunkAssembler(source: .roomMic)
    private var onChunk: ((AudioChunk) -> Void)?
    private var configObserver: NSObjectProtocol?
    /// Bumped on every engine stop, so samples an old tap queued are dropped after a restart.
    private var generation = 0

    public convenience init(clock: any TimeSource = SystemClock()) {
        self.init(resolver: .system, clock: clock)
    }

    init(resolver: DeviceResolver, clock: any TimeSource = SystemClock()) {
        self.resolver = resolver
        self.clock = clock
        queue.setSpecific(key: onQueue, value: ())
    }

    deinit {
        // The last release can happen inside a block on `queue`; `queue.sync` there would trap.
        if DispatchQueue.getSpecific(key: onQueue) != nil { tearDown() } else { stop() }
    }

    /// A second call while running does nothing: a second tap on the input bus would crash the engine.
    public func start(onChunk: @escaping (AudioChunk) -> Void) throws {
        guard let builtIn = resolver.builtIn() else { throw AudioError.noInput }
        guard resolver.defaultInput() != builtIn else { throw RoomMicError.redundantWithDefaultInput }
        // Checking status prompts nobody; starting the engine while undetermined would.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw AudioError.permissionDenied }
        try queue.sync {
            guard self.onChunk == nil else { return }
            try startEngine(on: builtIn)
            self.onChunk = onChunk  // set only once running, so a failed start can be retried
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                // Apple: never tear the engine down inside this handler; hop to our queue.
                self?.queue.async { [weak self] in self?.restart() }
            }
        }
    }

    public func stop() {
        queue.sync(execute: tearDown)
    }

    /// The built-in microphone: the first device with built-in transport and at least one input stream.
    public static func builtInDevice() -> AudioDeviceID? {
        deviceIDs().first { id in
            read(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn && hasInput(id)
        }
    }

    // MARK: on `queue`

    private func tearDown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        stopEngine()
        onChunk = nil
    }

    private func startEngine(on device: AudioDeviceID) throws {
        let input = engine.inputNode
        var device = device
        guard let unit = input.audioUnit,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
        else { throw AudioError.noInput }
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw AudioError.noInput }
        converter.downmix = true  // the built-in mic is an array; mix it rather than keep channel 0
        let generation = generation
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self, let samples = Self.convert(buffer, with: converter, to: outFormat) else { return }
            let heardAt = self.clock.now.addingTimeInterval(-Double(samples.count) / Self.sampleRate)
            self.queue.async { [weak self] in self?.take(samples, at: heardAt, from: generation) }
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
    }

    /// Drops the tap and ends the current chunk; the generation bump keeps samples the old tap already
    /// queued out of the next chunk, so no chunk spans the restart gap.
    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        generation += 1
        if let partial = chunks.flush() { onChunk?(partial) }
    }

    /// Re-pins after a configuration change. If the default input became the built-in mic meanwhile,
    /// the room stream would duplicate the mic, so it stays stopped; the facade decides what runs (T-24).
    private func restart() {
        guard onChunk != nil else { return }
        stopEngine()
        guard let builtIn = resolver.builtIn(), resolver.defaultInput() != builtIn else { return }
        try? startEngine(on: builtIn)
    }

    private func take(_ samples: [Float], at time: Date, from tapGeneration: Int) {
        guard tapGeneration == generation, let onChunk else { return }
        chunks.append(samples, at: time).forEach(onChunk)
    }

    // Duplicated from MicSource / AudioRouteMonitor, whose helpers are private (T-20 may not edit them).

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

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// A `UInt32` property (a transport type or a device ID).
    private static func read(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        let id = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        return id == kAudioObjectUnknown ? nil : id
    }
}

/// Why `RoomMicSource` will not start. Separate from `AudioError` only because T-20 may not edit that file.
public enum RoomMicError: Error, Equatable {
    /// The default input already is the built-in mic, so `MicSource` records the room; run only that.
    case redundantWithDefaultInput
}
