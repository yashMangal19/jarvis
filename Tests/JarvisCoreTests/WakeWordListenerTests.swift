import Foundation
import Testing
import JarvisCore

@MainActor
@Suite(.timeLimit(.minutes(1))) struct WakeWordListenerTests {
    private let heard = "jarvis what did prashant say about fpv"
    private let frames: AsyncStream<[Float]>
    private let mic: AsyncStream<[Float]>.Continuation

    init() { (frames, mic) = AsyncStream.makeStream(of: [Float].self) }

    private var capture: CommandCapture!

    private mutating func makeListener(wake: any Transcriber, command: any Transcriber) -> WakeWordListener {
        capture = CommandCapture(buffer: RollingAudioBuffer(seconds: 8), transcriber: { command },
                                 gate: SilenceGate(), clock: WakeTestClock())
        return WakeWordListener(mic: frames, wakeWordTranscriber: { wake }, capture: capture)
    }

    /// Waits until the listener has read `seconds` of audio off the mic stream.
    private func heard(_ seconds: TimeInterval) async {
        while capture.buffer.end < seconds && !Task.isCancelled { await Task.yield() }
    }

    private func say(speech: Int, silence: Int) {
        for _ in 0..<speech { mic.yield(wakeSpeechFrame()) }
        for _ in 0..<silence { mic.yield(wakeSilenceFrame()) }
    }

    // Story 25: "Jarvis …" in one breath chimes once and hands on the command without the wake word.
    @Test mutating func oneBreathCommandChimesOnceAndHandsOnTheTextAfterJarvis() async {
        let listener = makeListener(wake: WakeScriptedTranscriber(heard), command: WakeScriptedTranscriber(heard))
        var detections = 0
        listener.onDetected = { detections += 1 }
        listener.start()

        let command = await withCheckedContinuation { done in
            listener.onCommand = { done.resume(returning: $0) }
            say(speech: 8, silence: 8)
        }

        #expect(command == "what did prashant say about fpv")
        #expect(detections == 1)
    }

    // Story 25: "Jarvis." then a pause — the command after the chime is still captured.
    @Test mutating func aPauseAfterJarvisStillCapturesTheCommandThatFollows() async {
        let command = WakeScriptedTranscriber("Jarvis.", "What did Prashant say about FPV?")
        let listener = makeListener(wake: WakeScriptedTranscriber("Jarvis."), command: command)
        listener.start()

        let text = await withCheckedContinuation { done in
            listener.onCommand = { done.resume(returning: $0) }
            say(speech: 4, silence: 8)
            say(speech: 8, silence: 8)
        }

        #expect(text == "What did Prashant say about FPV?")
        #expect(command.chunks.count == 2)
    }

    // A slow wake-word engine never has two windows in flight; speech without "jarvis" does nothing.
    @Test mutating func aSlowWakeWordEngineSkipsWindowsInsteadOfPilingThemUp() async {
        let wake = WakeHeldTranscriber()
        let command = WakeScriptedTranscriber(heard)
        let listener = makeListener(wake: wake, command: command)
        var detections = 0
        listener.onDetected = { detections += 1 }
        listener.start()

        say(speech: 24, silence: 0)
        await heard(6)
        #expect(wake.calls == 1)

        wake.release("so what did prashant say")
        say(speech: 8, silence: 0)
        await heard(8)
        while wake.calls < 2 && !Task.isCancelled { await Task.yield() }
        wake.release("nothing here either")
        #expect(detections == 0 && command.chunks.isEmpty)
    }

    // Story 26 (⌥Space): hold-to-talk needs no wake word and a pause mid-hold does not end it.
    @Test mutating func holdCapturesFromBeginToEndWithoutTheWakeWord() async {
        let wake = WakeScriptedTranscriber("")
        let command = WakeScriptedTranscriber(heard)
        let listener = makeListener(wake: wake, command: command)

        let text = await withCheckedContinuation { done in
            listener.onCommand = { done.resume(returning: $0) }
            listener.beginHold()
            say(speech: 4, silence: 8)
            say(speech: 4, silence: 0)
            let capture = self.capture!
            Task { while capture.buffer.end < 4 && !Task.isCancelled { await Task.yield() }; listener.endHold() }
        }

        #expect(text == "what did prashant say about fpv")
        #expect(command.chunks.map(\.duration) == [4])
        #expect(wake.chunks.isEmpty)
    }

    // Story 27 (stem): press-to-talk ends by itself after 5 s of silence.
    @Test mutating func pressToTalkEndsAfterFiveSecondsOfSilence() async {
        let command = WakeScriptedTranscriber("send it")
        let listener = makeListener(wake: WakeScriptedTranscriber(""), command: command)

        let text = await withCheckedContinuation { done in
            listener.onCommand = { done.resume(returning: $0) }
            listener.pressToTalk()
            say(speech: 4, silence: 24)
        }

        #expect(text == "send it")
        #expect(command.chunks.map(\.duration) == [6])
    }

    // Story 29: the reply window hears a yes, and returns nil after 15 s of silence without transcribing.
    @Test mutating func listenForReplyReturnsTheReplyOrNilAfterFifteenSecondsOfSilence() async {
        let command = WakeScriptedTranscriber("Yes.")
        let listener = makeListener(wake: WakeScriptedTranscriber(""), command: command)

        let silent = Task { await listener.listenForReply(timeout: 15) }
        say(speech: 0, silence: 60)
        #expect(await silent.value == nil)
        #expect(command.chunks.isEmpty)

        let reply = Task { await listener.listenForReply(timeout: 15) }
        say(speech: 2, silence: 4)
        #expect(await reply.value == "Yes.")
    }
}

/// Holds every transcription until the test releases it.
final class WakeHeldTranscriber: Transcriber {
    private(set) var calls = 0
    private var held: CheckedContinuation<String, Never>?
    func transcribe(_ chunk: AudioChunk) async throws -> String {
        await withCheckedContinuation { held = $0; calls += 1 }
    }
    func release(_ text: String) {
        held?.resume(returning: text)
        held = nil
    }
}
