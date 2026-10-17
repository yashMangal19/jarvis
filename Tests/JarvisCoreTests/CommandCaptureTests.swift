import Foundation
import Testing
import JarvisCore

/// 250 ms of a 440 Hz tone at 16 kHz: loud enough to pass the silence gate, so it stands in for speech.
func wakeSpeechFrame() -> [Float] { (0..<4_000).map { 0.3 * sin(2 * .pi * 440 * Float($0) / 16_000) } }
/// 250 ms of digital silence.
func wakeSilenceFrame() -> [Float] { [Float](repeating: 0, count: 4_000) }

/// Returns `replies` in order, then the last one again; records every chunk it was given.
final class WakeScriptedTranscriber: Transcriber {
    private var replies: [String]
    var chunks: [AudioChunk] = []
    init(_ replies: String...) { self.replies = replies }
    func transcribe(_ chunk: AudioChunk) async throws -> String {
        chunks.append(chunk)
        return replies.count > 1 ? replies.removeFirst() : replies[0]
    }
}

final class WakeTestClock: TimeSource {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct CommandCaptureTests {
    private let transcriber = WakeScriptedTranscriber("  jarvis what did prashant say about fpv \n")

    private func makeCapture() -> CommandCapture {
        let transcriber = self.transcriber
        return CommandCapture(buffer: RollingAudioBuffer(seconds: 8), transcriber: { transcriber },
                              gate: SilenceGate(), clock: WakeTestClock())
    }

    @Test func captureEndsAfterOneSecondOfSilenceAndReturnsTheTrimmedText() async {
        let capture = makeCapture()
        let result = Task { await capture.capture(from: 0) }
        for _ in 0..<8 { capture.append(wakeSpeechFrame()) }
        for _ in 0..<4 { capture.append(wakeSilenceFrame()) }
        for _ in 0..<8 { capture.append(wakeSpeechFrame()) }  // after the end: not part of the command

        #expect(await result.value == "jarvis what did prashant say about fpv")
        #expect(transcriber.chunks.map(\.duration) == [3])
        #expect(transcriber.chunks.first?.source == .mic)
    }

    // Pausing the session mid-command drops it: no text, nothing transcribed.
    @Test func aCancelledCaptureReturnsNilWithoutTranscribing() async {
        let capture = makeCapture()
        let result = Task { await capture.capture(from: 0) }
        for _ in 0..<4 { capture.append(wakeSpeechFrame()) }
        capture.cancel()  // lands before the capture task has started

        #expect(await result.value == nil)
        #expect(transcriber.chunks.isEmpty)
    }

    // A cancel during transcription drops that text and does not leak into the next capture.
    @Test func aCancelDuringTranscriptionDropsTheTextAndNotTheNextCapture() async {
        let held = WakeHeldTranscriber()
        let capture = CommandCapture(buffer: RollingAudioBuffer(seconds: 8), transcriber: { held },
                                     gate: SilenceGate(), clock: WakeTestClock())
        let first = Task { await capture.capture(from: 0) }
        for _ in 0..<4 { capture.append(wakeSpeechFrame()) }
        for _ in 0..<4 { capture.append(wakeSilenceFrame()) }
        while held.calls < 1 && !Task.isCancelled { await Task.yield() }
        capture.cancel()
        held.release("send it")
        #expect(await first.value == nil)

        let next = capture.buffer.end
        let second = Task { await capture.capture(from: next) }
        for _ in 0..<4 { capture.append(wakeSpeechFrame()) }
        for _ in 0..<4 { capture.append(wakeSilenceFrame()) }
        while held.calls < 2 && !Task.isCancelled { await Task.yield() }
        held.release("send it")
        #expect(await second.value == "send it")
    }

    /// A capture whose wall clock jumps forward by however long it asks to sleep.
    private func makeCaptureWithInstantSleep() -> CommandCapture {
        let transcriber = self.transcriber
        let clock = WakeTestClock()
        return CommandCapture(buffer: RollingAudioBuffer(seconds: 8), transcriber: { transcriber },
                              gate: SilenceGate(), clock: clock, sleep: { clock.now += $0 })
    }

    // F-3: frames stop, the injected clock still ends the capture at `maxSeconds`.
    @Test func aCaptureEndsAtItsClockDeadlineWhenFramesStop() async {
        let capture = makeCaptureWithInstantSleep()

        #expect(await capture.capture(from: 0, maxSeconds: 15) == nil)
        #expect(transcriber.chunks.isEmpty)
    }

    // F-3: the mic stream ended — the running capture keeps what it heard, and every later one ends at once.
    @Test func closeEndsTheRunningCaptureAndEveryLaterOne() async {
        let capture = makeCapture()
        let first = Task { await capture.capture(from: 0) }
        for _ in 0..<4 { capture.append(wakeSpeechFrame()) }
        capture.close()
        #expect(await first.value == "jarvis what did prashant say about fpv")

        #expect(await capture.capture(from: capture.buffer.end) == nil)
    }

    // F-3: cancelling the caller's task ends the capture with no text.
    @Test func cancellingTheCallersTaskEndsTheCaptureWithoutTranscribing() async {
        let capture = makeCapture()
        let result = Task { await capture.capture(from: 0) }
        for _ in 0..<4 { capture.append(wakeSpeechFrame()) }
        await Task.yield()
        result.cancel()

        #expect(await result.value == nil)
        #expect(transcriber.chunks.isEmpty)
    }

    // F-6: one capture at a time — a second one returns nil at once and the first is unharmed.
    @Test func aSecondConcurrentCaptureReturnsNilAndTheFirstStillCompletes() async {
        let capture = makeCapture()
        let first = Task { await capture.capture(from: 0) }
        await Task.yield()

        #expect(await capture.capture(from: 0) == nil)

        for _ in 0..<4 { capture.append(wakeSpeechFrame()) }
        for _ in 0..<4 { capture.append(wakeSilenceFrame()) }
        #expect(await first.value == "jarvis what did prashant say about fpv")
    }

    // F-4: press-to-talk's silence counts from the press — nobody speaking for 5 s ends it.
    @Test func startSilenceEndsACaptureNobodySpokeInto() async {
        let capture = makeCapture()
        let result = Task { await capture.capture(from: 0, endSilence: 1, startSilence: 5) }
        for _ in 0..<20 { capture.append(wakeSilenceFrame()) }
        for _ in 0..<4 { capture.append(wakeSpeechFrame()) }   // too late: the capture is over
        for _ in 0..<4 { capture.append(wakeSilenceFrame()) }  // 7 s in all, inside the 8 s buffer

        #expect(await result.value == nil)
        #expect(transcriber.chunks.isEmpty)
    }
}
