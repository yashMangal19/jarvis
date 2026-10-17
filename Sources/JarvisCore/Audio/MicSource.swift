import AVFoundation

/// The active microphone as 30 s, 16 kHz mono chunks, plus a tee of 250 ms frames for the wake-word
/// listener. Follows the default input: the engine restarts on `.AVAudioEngineConfigurationChange`.
/// Never requests microphone permission; without it `start` throws `AudioError.permissionDenied`.
public final class MicSource: AudioSourceStream {
    /// 250 ms frames of 16 kHz mono samples. Keeps only the newest few if nobody is reading.
    public let frames: AsyncStream<[Float]>

    private static let sampleRate = 16_000.0
    private let framesOut: AsyncStream<[Float]>.Continuation
    private let clock: any TimeSource
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "jarvis.mic")
    private var chunks = ChunkAssembler(source: .mic)
    private var frameCutter = ChunkAssembler(chunkSeconds: 0.25, source: .mic)
    private var onChunk: ((AudioChunk) -> Void)?
    private var configObserver: NSObjectProtocol?

    public init(clock: any TimeSource = SystemClock()) {
        self.clock = clock
        (frames, framesOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    deinit {
        stop()
        framesOut.finish()
    }

    public func start(onChunk: @escaping (AudioChunk) -> Void) throws {
        // Checking status prompts nobody; starting the engine while undetermined would.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw AudioError.permissionDenied }
        try queue.sync {
            self.onChunk = onChunk
            try startEngine()
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                // Apple: never tear the engine down inside this handler; hop to our queue.
                self?.queue.async { self?.restart() }
            }
        }
    }

    public func stop() {
        queue.sync {
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            configObserver = nil
            stopEngine()
            onChunk = nil
        }
    }

    // MARK: on `queue`

    private func startEngine() throws {
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw AudioError.noInput }
        converter.downmix = true  // mix a multi-channel mic to mono rather than keep channel 0
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self, let samples = Self.convert(buffer, with: converter, to: outFormat) else { return }
            let heardAt = self.clock.now.addingTimeInterval(-Double(samples.count) / Self.sampleRate)
            self.queue.async { self.take(samples, at: heardAt) }
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
    }

    /// Ends the current chunk so its timestamps stay honest across the gap, then drops the tap.
    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let partial = chunks.flush() { onChunk?(partial) }
        _ = frameCutter.flush()
    }

    private func restart() {
        guard onChunk != nil else { return }
        stopEngine()
        // A device with no usable input (e.g. the default went away) stays stopped until the next change.
        try? startEngine()
    }

    private func take(_ samples: [Float], at time: Date) {
        guard let onChunk else { return }
        chunks.append(samples, at: time).forEach(onChunk)
        frameCutter.append(samples, at: time).forEach { framesOut.yield($0.samples) }
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
