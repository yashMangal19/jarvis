import Foundation

/// Listens on the mic for "Jarvis", then captures the command that follows it — no pause needed.
/// Also serves hold-to-talk, press-to-talk and the yes/no reply window, one capture at a time.
/// Reads every frame into the capture's in-memory buffer; nothing is written to disk.
@MainActor
public final class WakeWordListener {
    /// The wake word was heard (the chime).
    public var onDetected: () -> Void = {}
    /// The command text, without the wake word.
    public var onCommand: (String) -> Void = { _ in }

    /// Audio-time cadence and window of the wake-word check (≈ every 1 s, the last 2.5 s).
    private static let checkEvery = 4
    private static let windowSeconds = 2.5

    private let wakeWordTranscriber: () -> (any Transcriber)?
    private let capture: CommandCapture
    private let gate = SilenceGate()
    private var listening = false
    private var transcribing = false
    private var capturing = false
    private var manual = false
    private var framesSinceCheck = 0
    /// Audio before this stream time was already acted on; a later window never hears it again.
    private var heardUpTo: TimeInterval = 0

    public init(mic frames: AsyncStream<[Float]>, wakeWordTranscriber: @escaping () -> (any Transcriber)?,
                capture: CommandCapture) {
        self.wakeWordTranscriber = wakeWordTranscriber
        self.capture = capture
        // One reader for the stream's whole life: cancelling a reader would end the stream.
        Task { [weak self] in
            for await frame in frames {
                guard let self else { return }
                self.take(frame)
            }
        }
    }

    /// Starts looking for the wake word (driven by `session.wakeWordActive`).
    public func start() { listening = true }

    /// Stops looking for the wake word and drops any capture in progress.
    public func stop() {
        listening = false
        if capturing { capture.cancel() }
    }

    /// Hotkey down: capture from now until `endHold`, no wake word, a pause does not end it.
    public func beginHold() { beginManual(endSilence: .infinity) }

    /// Hotkey up: the held audio becomes the command.
    public func endHold() { if manual { capture.finish() } }

    /// Stem press: the first press starts a capture, a second press or 5 s of silence ends it.
    public func pressToTalk() {
        if manual { capture.finish() } else { beginManual(endSilence: 5) }
    }

    /// The spoken reply after a read-back, or `nil` when nothing is said within `timeout` seconds.
    public func listenForReply(timeout: TimeInterval = 15) async -> String? {
        guard !capturing else { return nil }
        capturing = true
        let reply = await capture.capture(from: capture.buffer.end, maxSeconds: timeout)
        heardUpTo = capture.lastEnd
        capturing = false
        return reply
    }

    private func beginManual(endSilence: TimeInterval) {
        guard !capturing else { return }
        capturing = true
        manual = true
        let start = capture.buffer.end
        Task {
            let text = await capture.capture(from: start, endSilence: endSilence)
            finishCapture(text.map(Self.withoutLeadingWakeWord))
        }
    }

    private func take(_ frame: [Float]) {
        capture.append(frame)
        framesSinceCheck += 1
        guard framesSinceCheck >= Self.checkEvery else { return }
        framesSinceCheck = 0
        check()
    }

    /// Transcribes the latest window unless one is still in flight — a slow engine skips windows
    /// rather than piling them up.
    private func check() {
        guard listening, !transcribing, !capturing, let transcriber = wakeWordTranscriber() else { return }
        let from = max(heardUpTo, capture.buffer.end - Self.windowSeconds)
        let window = capture.buffer.samples(from: from)
        guard !gate.isSilent(frame: window, sampleRate: capture.buffer.sampleRate) else { return }
        transcribing = true
        Task {
            let text = (try? await transcriber.transcribe(
                AudioChunk(samples: window, sampleRate: capture.buffer.sampleRate,
                           start: capture.date(of: from), source: .mic))) ?? ""
            transcribing = false
            guard listening, !capturing, Self.afterWakeWord(text) != nil else { return }
            await commandAfterWakeWord(utteranceStart(in: window, from: from))
        }
    }

    private func commandAfterWakeWord(_ start: TimeInterval) async {
        capturing = true
        onDetected()
        // The window's utterance usually holds "Jarvis" and the command's first words.
        var command = await capture.capture(from: start).map { Self.afterWakeWord($0) ?? $0 }
        // "Jarvis." then a pause: the command is still to come.
        if command?.isEmpty == true, listening {
            command = await capture.capture(from: capture.lastEnd).map(Self.withoutLeadingWakeWord)
        }
        finishCapture(command)
    }

    private func finishCapture(_ command: String?) {
        heardUpTo = capture.lastEnd
        capturing = false
        manual = false
        if let command, !command.isEmpty { onCommand(command) }
    }

    /// Where the utterance reaching the end of `window` began: just after its last pause of at
    /// least the capture's end-silence before the final speech, else the window start.
    private func utteranceStart(in window: [Float], from: TimeInterval) -> TimeInterval {
        let rate = capture.buffer.sampleRate
        let length = Int(CommandCapture.frameSeconds * rate)
        let pause = Int(1.0 / CommandCapture.frameSeconds)
        var spoke = false
        var silent = 0
        for i in stride(from: window.count / length - 1, through: 0, by: -1) {
            if !gate.isSilent(frame: Array(window[i * length..<(i + 1) * length]), sampleRate: rate) {
                spoke = true
                silent = 0
            } else if spoke {
                silent += 1
                if silent == pause { return from + Double((i + pause) * length) / rate }
            }
        }
        return from
    }

    /// The words after the first "jarvis" token, or `nil` when there is none.
    static func afterWakeWord(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard let hit = words.firstIndex(where: isWakeWord) else { return nil }
        return words[(hit + 1)...].joined(separator: " ")
    }

    static func withoutLeadingWakeWord(_ text: String) -> String {
        guard let first = text.split(whereSeparator: \.isWhitespace).first, isWakeWord(first) else { return text }
        return afterWakeWord(text) ?? text
    }

    /// "jarvis" in any case, with surrounding punctuation allowed ("Jarvis," "jarvis?").
    private static func isWakeWord(_ word: Substring) -> Bool {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters) == "jarvis"
    }
}
