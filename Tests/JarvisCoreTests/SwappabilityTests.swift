import Foundation
import Testing
@testable import JarvisCore

/// The contributor promise: fake engines in all four protocols run the whole loop. Nothing here can
/// reach a concrete engine, a microphone, the screen, Voice Memos or a whisper-server process.
@MainActor
@Suite(.timeLimit(.minutes(1))) final class SwappabilityTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-swap-\(UUID().uuidString)")
    private lazy var paths = JarvisPaths(root: root)
    private let clock = SwapClock(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14,
                                                                             hour: 10, minute: 15))!)
    private let sources = FakeSourceFactory()
    private let routes = SwapRoutes()
    private let transcriber = SwapTranscriber()
    private let wake = SwapTranscriber()
    private let writer = SwapNoteWriter()
    private let runner = SwapCommandRunner()
    private var spoken: [String] = []
    private var chimes = 0

    deinit { try? FileManager.default.removeItem(at: root) }

    private func makeJarvis() -> Jarvis {
        let engines = Engines(transcriber: transcriber, wakeWordTranscriber: wake, noteWriter: writer,
                              embedder: SwapEmbedder(), commandRunner: runner,
                              description: EnginesDescription(speech: "fake speech", notes: "fake notes",
                                                              search: "fake search"))
        let jarvis = Jarvis(paths: paths, engines: engines, settings: SettingsStore(paths: paths), clock: clock,
                            sources: sources, screenLock: SwapScreenLock(), sleepGuard: SwapSleepGuard(),
                            routes: routes, voiceMemos: { .absent })
        jarvis.speak = { [unowned self] in spoken.append($0) }
        jarvis.onChime = { [unowned self] in chimes += 1 }
        return jarvis
    }

    private func transcriptText() -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.transcripts, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
    }

    private func hourlyNote(_ id: String) -> String? {
        try? String(contentsOf: paths.notesHourly.appending(path: "\(id).md"), encoding: .utf8)
    }

    /// Says `text` into the live mic as one chunk heard at the clock's now.
    private func sayChunk(_ text: String, on stream: FakeSource? = nil, from source: AudioSource = .mic,
                          startingAt start: Date? = nil, seconds: Double = 1) {
        let start = start ?? clock.now
        transcriber.said[start] = text
        (stream ?? sources.mic).emit(AudioChunk(samples: swapSpeech(seconds: seconds), sampleRate: 16_000,
                                                start: start, source: source))
    }

    // Stories 9, 13, 22, 25, 28, 31 end to end, every engine a fake.
    @Test func fakeEnginesInAllFourProtocolsRunTheWholeLoop() async throws {
        let jarvis = makeJarvis()
        await jarvis.start()
        await swapWaitUntil { self.sources.mic.isRunning }

        sayChunk("We ship the launch on Friday.")
        await swapWaitUntil { self.transcriptText().contains("We ship the launch on Friday.") }
        #expect(transcriptText().contains("We ship the launch on Friday."))
        #expect(jarvis.session.state == .listening)

        clock.now += 3600
        await jarvis.tick()
        let noteID = "2026-10-14-10"
        #expect(hourlyNote(noteID)?.contains("Decided: ship on Friday.") == true)

        let answer = await jarvis.askMemory("What did we decide about Friday?")
        #expect(answer.usedNoteIDs == [noteID])
        #expect(answer.text == "You decided to ship on Friday (\(noteID)).")

        wake.saying = "Jarvis, create a file"
        transcriber.saying = "Jarvis, create a file"
        sources.say(speech: 8, silence: 8)
        await swapWaitUntil { self.spoken.contains(SwapCommandRunner.draft) }
        #expect(chimes == 1)
        wake.saying = ""
        transcriber.saying = "yes"
        await swapWaitUntil {
            if self.runner.executed.isEmpty { self.sources.say(speech: 4, silence: 6) }
            return !self.runner.executed.isEmpty
        }
        await swapWaitUntil { self.spoken.contains(SwapCommandRunner.result) }
        #expect(runner.executed == [SwapCommandRunner.draft])
        #expect(spoken.contains(SwapCommandRunner.result))
        await jarvis.shutdown()
    }

    // Stories 8, 25b: while Paused only the wake word runs and nothing heard is stored, not even the
    // paused part of a chunk that is still being recorded when listening resumes.
    @Test func speechHeardWhilePausedIsNeverStored() async throws {
        let jarvis = makeJarvis()
        await jarvis.start()
        await swapWaitUntil { self.sources.systemAudio.isRunning }

        jarvis.session.pause(.user)
        await swapWaitUntil { !self.sources.systemAudio.isRunning }
        #expect(sources.mic.isRunning)
        clock.now += 10
        sayChunk("Paused secret one.")
        let spanningStart = clock.now
        clock.now += 20
        jarvis.session.resume()
        clock.now += 10
        sayChunk("Paused secret two.", startingAt: spanningStart, seconds: 30)
        sayChunk("Back to listening.")
        await swapWaitUntil { self.transcriptText().contains("Back to listening.") }

        #expect(transcriptText().contains("Back to listening."))
        #expect(!transcriptText().contains("secret"))
        await jarvis.shutdown()
    }

    // Story 4b: Meeting mode adds the room mic, labelled Others. When the input moves to the built-in mic
    // the room stream would duplicate it, so a route change stops it and it is not started again.
    @Test func meetingModeRunsTheRoomMicUntilARouteChangeMakesItRedundant() async throws {
        let jarvis = makeJarvis()
        await jarvis.start()
        jarvis.session.modes.meetingMode = true
        await swapWaitUntil { self.sources.roomMic.isRunning }
        #expect(sources.roomMic.isRunning)
        sayChunk("The room agrees on Friday.", on: sources.roomMic, from: .roomMic)
        await swapWaitUntil { self.transcriptText().contains("The room agrees on Friday.") }
        #expect(transcriptText().contains("\"Others\""))

        sources.roomMic.startError = .redundantWithDefaultInput
        routes.onEvent?(.inputChanged(InputDevice(name: "MacBook Pro Microphone", isBluetoothHeadset: false)))
        await swapWaitUntil { !self.sources.roomMic.isRunning }

        #expect(!sources.roomMic.isRunning)
        #expect(sources.mic.isRunning)
        #expect(jarvis.session.state == .listening)
        await jarvis.shutdown()
    }

    // Story 8a: Stop turns every source off. Holding the command key while stopped runs the mic only for
    // the hold, and nothing it hears is stored.
    @Test func stopTurnsEverySourceOffAndTheHoldKeyRunsTheMicOnlyWhileHeld() async throws {
        let jarvis = makeJarvis()
        await jarvis.start()
        jarvis.session.modes.meetingMode = true
        await swapWaitUntil { self.sources.roomMic.isRunning }

        jarvis.session.stop(.user)
        await swapWaitUntil { !self.sources.mic.isRunning }
        #expect(!sources.mic.isRunning && !sources.systemAudio.isRunning && !sources.roomMic.isRunning)

        jarvis.beginHoldCommand()
        #expect(sources.mic.isRunning)
        clock.now += 5
        sayChunk("Held while stopped.", startingAt: clock.now.addingTimeInterval(-2))
        jarvis.endHoldCommand()
        #expect(!sources.mic.isRunning)
        #expect(!sources.systemAudio.isRunning && !sources.roomMic.isRunning)
        #expect(jarvis.session.state == .stopped(.user))

        jarvis.session.start()
        await swapWaitUntil { self.sources.mic.isRunning }
        clock.now += 5
        sayChunk("Listening again.")
        await swapWaitUntil { self.transcriptText().contains("Listening again.") }
        #expect(!transcriptText().contains("Held while stopped."))
        await jarvis.shutdown()
    }

    // Story 14: maintenance runs every hour after the hourly note, so the first tick after midnight writes
    // the 23:00 note and then the day's note that includes it.
    @Test func theDayRollsUpWithItsLastHourOnTheFirstHourlyRunAfterMidnight() async throws {
        clock.now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 23, minute: 15))!
        let jarvis = makeJarvis()
        await jarvis.start()
        await swapWaitUntil { self.sources.mic.isRunning }
        sayChunk("Late call: we ship on Friday.")
        await swapWaitUntil { self.transcriptText().contains("Late call") }

        clock.now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 0, minute: 20))!
        await jarvis.tick()

        #expect(hourlyNote("2026-10-14-23") != nil)
        let daily = try? String(contentsOf: paths.notesDaily.appending(path: "2026-10-14.md"), encoding: .utf8)
        #expect(daily?.contains("Decided: ship on Friday.") == true)
        await jarvis.shutdown()
    }

    // Story 21, DEC-12: forgetting the last hour also drops speech from that hour still being transcribed,
    // because capture and forget share one record of forgotten windows.
    @Test func forgettingTheLastHourAlsoDropsSpeechStillInFlightFromIt() async throws {
        let jarvis = makeJarvis()
        await jarvis.start()
        await swapWaitUntil { self.sources.mic.isRunning }
        sayChunk("Forget this plan.")
        await swapWaitUntil { self.transcriptText().contains("Forget this plan.") }
        clock.now += 60
        let inFlight = clock.now.addingTimeInterval(-30)

        #expect(try jarvis.forgetLastHourDescription().contains("1 transcript line"))
        try jarvis.forgetLastHour()
        sayChunk("Still in flight.", startingAt: inFlight)
        clock.now += 1
        sayChunk("After forgetting.")
        await swapWaitUntil { self.transcriptText().contains("After forgetting.") }

        #expect(!transcriptText().contains("Forget this plan."))
        #expect(!transcriptText().contains("Still in flight."))
        await jarvis.shutdown()
    }

    // D-8: while Jarvis speaks, its own voice cannot trigger the wake word.
    @Test func theWakeWordIsMutedWhileJarvisSpeaks() async throws {
        let jarvis = makeJarvis()
        await jarvis.start()
        await swapWaitUntil { self.sources.mic.isRunning }
        wake.saying = "Jarvis, what did we decide"
        transcriber.saying = "Jarvis, what did we decide"

        jarvis.isSpeaking = true
        await Task.yield()
        sources.say(speech: 8, silence: 8)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(chimes == 0)

        jarvis.isSpeaking = false
        await swapWaitUntil {
            if self.chimes == 0 { self.sources.say(speech: 8, silence: 8) }
            return self.chimes > 0
        }
        #expect(chimes == 1)
        await jarvis.shutdown()
    }

    // Story 7, DEC-14: quiet hours from Settings stop everything, wake word included.
    @Test func quietHoursFromSettingsStopEverySource() async throws {
        try SettingsStore(paths: paths).save(Settings(quietHours: QuietHours(startMinutes: 11 * 60, endMinutes: 12 * 60)))
        let jarvis = makeJarvis()
        await jarvis.start()
        await swapWaitUntil { self.sources.mic.isRunning }

        clock.now += 3600
        await jarvis.tick()
        await swapWaitUntil { !self.sources.mic.isRunning }

        #expect(jarvis.session.state == .stopped(.quietHours))
        #expect(!sources.mic.isRunning && !sources.systemAudio.isRunning)
        await jarvis.shutdown()
    }
}

// MARK: - Fakes

/// Polls `condition` every 20 ms for up to `timeout` seconds.
@MainActor func swapWaitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
}

func swapSpeech(seconds: Double) -> [Float] {
    (0..<Int(seconds * 16_000)).map { 0.3 * sin(2 * .pi * 440 * Float($0) / 16_000) }
}

final class SwapClock: TimeSource {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// Returns what was said in the chunk starting at that time, else whatever is being said now.
final class SwapTranscriber: Transcriber {
    var saying = ""
    var said: [Date: String] = [:]
    func transcribe(_ chunk: AudioChunk) async throws -> String { said[chunk.start] ?? saying }
}

/// An hourly note states the decision; an answer names the first note it was given.
final class SwapNoteWriter: NoteWriter {
    func note(from transcript: String, prompt: String) async throws -> String {
        guard prompt.contains("Question:") else {
            return transcript.contains("Friday") ? "Decided: ship on Friday." : "Nothing decided."
        }
        let id = transcript.components(separatedBy: "### ").dropFirst().first?.prefix { $0 != "\n" } ?? "none"
        return "You decided to ship on Friday (\(id))."
    }
}

/// Every text shares one direction, so every note matches every question.
struct SwapEmbedder: Embedder {
    func embed(_ text: String) throws -> [Float] { [1, text.contains("Friday") ? 1 : 0] }
}

final class SwapCommandRunner: CommandRunner {
    static let draft = "I will create a file called plan.txt."
    static let result = "Created plan.txt."
    var executed: [String] = []
    func draft(_ command: String) async throws -> String { Self.draft }
    func execute(_ draft: String) async throws -> String {
        executed.append(draft)
        return Self.result
    }
}

final class FakeSource: AudioSourceStream {
    var startError: AudioError?
    private(set) var isRunning = false
    private(set) var stops = 0
    private var onChunk: ((AudioChunk) -> Void)?

    func start(onChunk: @escaping (AudioChunk) -> Void) throws {
        if let startError { throw startError }
        isRunning = true
        self.onChunk = onChunk
    }

    func stop() {
        if isRunning { stops += 1 }
        isRunning = false
        onChunk = nil
    }

    /// Delivers `chunk` as the live source would, only while running.
    func emit(_ chunk: AudioChunk) { onChunk?(chunk) }
}

/// Fake capture streams: no microphone, no screen capture.
final class FakeSourceFactory: SourceFactory {
    let mic = FakeSource()
    let systemAudio = FakeSource()
    let roomMic = FakeSource()
    private let frames: AsyncStream<[Float]>
    private let framesIn: AsyncStream<[Float]>.Continuation

    init() { (frames, framesIn) = AsyncStream.makeStream(of: [Float].self) }

    func makeMic() -> (chunks: any AudioSourceStream, frames: AsyncStream<[Float]>) { (mic, frames) }
    func makeSystemAudio() -> any AudioSourceStream { systemAudio }
    func makeRoomMic() -> any AudioSourceStream { roomMic }

    /// 250 ms mic frames of speech, then of silence, while the mic runs.
    func say(speech: Int, silence: Int) {
        guard mic.isRunning else { return }
        for _ in 0..<speech { framesIn.yield(wakeSpeechFrame()) }
        for _ in 0..<silence { framesIn.yield(wakeSilenceFrame()) }
    }
}

final class SwapRoutes: RouteEventSource {
    var onEvent: ((RouteEvent) -> Void)?
    var current: InputDevice? = InputDevice(name: "AirPods Pro", isBluetoothHeadset: true)
}

final class SwapScreenLock: ScreenLockObserving {
    var onLock: (() -> Void)?
    var onUnlock: (() -> Void)?
}

final class SwapSleepGuard: SleepGuard {
    func hold() {}
    func release() {}
}
