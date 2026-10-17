import Foundation

/// Turns live mic frames into one command's text: everything from a start point until the speaker
/// has been quiet for `endSilence`, `maxSeconds` have passed, or `finish()` is called.
/// The audio lives in the rolling buffer and in this capture's memory only; nothing reaches the disk.
/// Time is audio time — 250 ms frames counted as they arrive — so a paused mic pauses the clock too.
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
    private var waiting: CheckedContinuation<Void, Never>?
    private var ending: Ending?

    private enum Ending { case finish, cancel }

    public init(buffer: RollingAudioBuffer, transcriber: @escaping () -> (any Transcriber)?,
                gate: SilenceGate, clock: any TimeSource) {
        self.buffer = buffer
        self.transcriber = transcriber
        self.gate = gate
        self.clock = clock
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

    /// Ends the running capture (or the next one, if it has not started) with no text.
    public func cancel() {
        ending = .cancel
        resume()
    }

    /// The text spoken from stream time `start`, or `nil` when nothing was said, the capture was
    /// cancelled, there is no transcriber, or the transcript is empty. Silence before the first
    /// spoken frame never ends a capture; only `maxSeconds` does, so a reply window can wait.
    public func capture(from start: TimeInterval, maxSeconds: TimeInterval = 15,
                        endSilence: TimeInterval = 1.0) async -> String? {
        // Cleared only when a capture returns, so a cancel that lands before it starts still holds.
        defer { ending = nil }
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
                    if spoke { silentFrames += 1 }
                } else {
                    spoke = true
                    silentFrames = 0
                }
                if spoke && Double(silentFrames) * Self.frameSeconds >= endSilence
                    || Double(heard.count) / buffer.sampleRate >= maxSeconds { break reading }
            }
            if ending != nil { break }
            await withCheckedContinuation { waiting = $0 }
        }
        lastEnd = position
        guard spoke, ending != .cancel, let transcriber = transcriber() else { return nil }
        let chunk = AudioChunk(samples: heard, sampleRate: buffer.sampleRate, start: startDate, source: .mic)
        // A cancel while transcribing drops the text too.
        guard let raw = try? await transcriber.transcribe(chunk), ending != .cancel else { return nil }
        let text = TranscriptText.clean(raw)
        return text.isEmpty ? nil : text
    }

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
