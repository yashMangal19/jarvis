import Foundation

/// Turns live mic frames into one command's text: everything from a start point until the speaker
/// has been quiet for `endSilence`, `maxSeconds` have passed, or `finish()` is called.
/// Raw audio and the disk: the audio lives in the rolling buffer and in this capture's memory, and goes
/// only to the injected `Transcriber`. Whether it then touches the disk is that transcriber's business —
/// `WhisperTranscriber`'s server backend posts it from memory; its CLI fallback writes a short-lived
/// temp WAV, the one documented exception.
/// Time is audio time — 250 ms frames counted as they arrive — so a paused mic pauses the clock too.
/// `maxSeconds` is also a wall-clock bound on the injected `clock`, so a capture ends even when frames stop.
/// One capture at a time: a `capture` started while another is running returns `nil` at once.
@MainActor
public final class CommandCapture {
    /// The audio heard so far. Feed it through `append`.
    public private(set) var buffer: RollingAudioBuffer
    /// Stream time just after the last frame the latest capture consumed.
    private(set) var lastEnd: TimeInterval = 0

    static let frameSeconds = 0.25
    private let transcriber: () -> (any Transcriber)?
    private let gate: SilenceGate
    private let clock: any TimeSource
    private let sleep: (TimeInterval) async -> Void
    private var waiting: CheckedContinuation<Void, Never>?
    private var ending: Ending?
    private var running = false
    private var closed = false

    private enum Ending { case finish, cancel }

    /// `sleep` waits that many seconds of `clock` time; it wakes a capture to check its deadline.
    public init(buffer: RollingAudioBuffer, transcriber: @escaping () -> (any Transcriber)?,
                gate: SilenceGate, clock: any TimeSource,
                sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.buffer = buffer
        self.transcriber = transcriber
        self.gate = gate
        self.clock = clock
        self.sleep = sleep
    }

    /// One live frame from the mic.
    public func append(_ frame: [Float]) {
        buffer.append(frame)
        resume()
    }

    /// Ends the running capture (or the next one, if it has not started) with the audio heard so far.
    public func finish() {
        ending = .finish
        resume()
    }

    /// No more frames will come (the mic stream ended): ends the running capture with the audio heard
    /// so far, and every later capture at once.
    public func close() {
        closed = true
        resume()
    }

    /// Ends the running capture (or the next one, if it has not started) with no text.
    public func cancel() {
        ending = .cancel
        resume()
    }

    /// The text spoken from stream time `start`, or `nil` when nothing was said, the capture was
    /// cancelled (by `cancel()` or by cancelling the calling task), there is no transcriber, the
    /// transcript is empty, or another capture is running. Silence before the first spoken frame ends a
    /// capture only after `startSilence`; otherwise only `maxSeconds` does, so a reply window can wait.
    public func capture(from start: TimeInterval, maxSeconds: TimeInterval = 15,
                        endSilence: TimeInterval = 1.0, startSilence: TimeInterval = .infinity) async -> String? {
        guard !running else { return nil }
        running = true
        // `ending` is cleared only when a capture returns, so a cancel that lands before it starts still holds.
        defer { ending = nil; running = false }
        let deadline = clock.now.addingTimeInterval(maxSeconds)
        let watchdog = Task { [sleep] in
            await sleep(maxSeconds)
            if !Task.isCancelled { self.resume() }
        }
        defer { watchdog.cancel() }
        let frameLength = Int(Self.frameSeconds * buffer.sampleRate)
        let startDate = date(of: start)
        var position = start
        var heard: [Float] = []
        var spoke = false
        var silentFrames = 0
        reading: while true {
            let fresh = buffer.samples(from: position)
            position = buffer.end - Double(fresh.count) / buffer.sampleRate
            for i in stride(from: 0, to: fresh.count - frameLength + 1, by: frameLength) {
                let frame = Array(fresh[i..<i + frameLength])
                heard += frame
                position += Self.frameSeconds
                if gate.isSilent(frame: frame, sampleRate: buffer.sampleRate) {
                    silentFrames += 1
                } else {
                    spoke = true
                    silentFrames = 0
                }
                let silence = Double(silentFrames) * Self.frameSeconds
                if silence >= (spoke ? endSilence : startSilence)
                    || Double(heard.count) / buffer.sampleRate >= maxSeconds { break reading }
            }
            if ending != nil || closed || Task.isCancelled || clock.now >= deadline { break }
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiting = $0 }
            } onCancel: {
                Task { @MainActor in self.resume() }
            }
        }
        lastEnd = position
        guard spoke, !isCancelled, let transcriber = transcriber() else { return nil }
        let chunk = AudioChunk(samples: heard, sampleRate: buffer.sampleRate, start: startDate, source: .mic)
        // A cancel while transcribing drops the text too.
        guard let raw = try? await transcriber.transcribe(chunk), !isCancelled else { return nil }
        let text = TranscriptText.clean(raw)
        return text.isEmpty ? nil : text
    }

    private var isCancelled: Bool { ending == .cancel || Task.isCancelled }

    /// The wall-clock time at which stream time `offset` was heard.
    func date(of offset: TimeInterval) -> Date {
        clock.now.addingTimeInterval(offset - buffer.end)
    }

    private func resume() {
        waiting?.resume()
        waiting = nil
    }
}

extension SilenceGate {
    func isSilent(frame: [Float], sampleRate: Double) -> Bool {
        isSilent(AudioChunk(samples: frame, sampleRate: sampleRate, start: .distantPast, source: .mic))
    }
}
