import AVFAudio
import Foundation
import Testing
@testable import JarvisCore

/// The contributor promise: fake engines in all four protocols run the whole loop. Nothing here can
/// reach a concrete engine, a microphone, the screen, Voice Memos or a whisper-server process.
///
/// "Any concrete engine reached inside fails it" holds by construction: `Jarvis.init` builds no engine
/// and reads speech, notes, search and commands only through the injected `Engines` (D-4). Only
/// `Jarvis.live()` picks concrete engines, and no test calls it. A stage that built its own engine
/// would reach for a real binary or model here, and these tests would fail or hang on it.
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

    private let screenLock = SwapScreenLock()
    private let permissions = SwapPermissions()

    /// `speechOff` starts with no transcriber, as on a Mac whose whisper model is still downloading.
    private func makeJarvis(speechOff: Bool = false, tickInterval: TimeInterval = 30) -> Jarvis {
        let engines = Engines(transcriber: speechOff ? nil : transcriber, wakeWordTranscriber: speechOff ? nil : wake,
                              noteWriter: writer, embedder: SwapEmbedder(), commandRunner: runner,
                              description: EnginesDescription(speech: speechOff ? "none — run install.sh" : "fake speech",
                                                              notes: "fake notes", search: "fake search"))
        let jarvis = Jarvis(paths: paths, engines: engines, settings: SettingsStore(paths: paths), clock: clock,
                            sources: sources, screenLock: screenLock, sleepGuard: SwapSleepGuard(),
                            routes: routes, voiceMemos: { .absent }, permissions: permissions.status,
                            tickInterval: tickInterval)
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

    /// Says `text` into `stream` as the start of a chunk still being recorded: it is delivered only when
    /// the stream is cut or stopped, as `MicSource` hands over its partial chunk.
    private func hear(_ text: String, on stream: FakeSource? = nil, from source: AudioSource = .mic,
                      seconds: Double = 1) {
        transcriber.said[clock.now] = text
        (stream ?? sources.mic).hear(AudioChunk(samples: swapSpeech(seconds: seconds), sampleRate: 16_000,
                                                start: clock.now, source: source))
    }

    /// A 5 s speech-level WAV in the inbox, dated `recordedAt` through its creation date.
    private func inboxRecording(recordedAt: Date, saying text: String) throws -> URL {
        try FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
        let url = paths.inbox.appending(path: "memo-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let samples = swapSpeech(seconds: 5)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, sample) in samples.enumerated() { buffer.floatChannelData![0][i] = sample }
        do { try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer) }
        try FileManager.default.setAttributes([.creationDate: recordedAt], ofItemAtPath: url.path)
        transcriber.said[recordedAt] = text
        return url
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
    // paused part of a chunk still being recorded when listening resumes: resuming cuts it there.
    @Test func speechHeardWhilePausedIsNeverStored() async throws {
        let jarvis = makeJarvis()
        await jarvis.start()
        await swapWaitUntil { self.sources.systemAudio.isRunning }

        jarvis.session.pause(.user)
        await swapWaitUntil { !self.sources.systemAudio.isRunning }
        #expect(sources.mic.isRunning)
        clock.now += 10
        sayChunk("Paused secret one.")
        clock.now += 1
        hear("Paused secret two.", seconds: 20)
        clock.now += 20
        jarvis.session.resume()
        clock.now += 10
        sayChunk("Back to listening.")
        await swapWaitUntil { self.transcriptText().contains("Back to listening.") }

        #expect(transcriptText().contains("Back to listening."))
        #expect(!transcriptText().contains("secret"))
        await jarvis.shutdown()
    }

    // F-H4, DEC-24: every listening boundary cuts the chunk being recorded, so speech heard just before a
    // pause or a stop is kept instead of being dropped with the paused part.
    @Test func speechHeardJustBeforeAPauseOrAStopIsKept() async throws {
        let jarvis = makeJarvis()
        await jarvis.start()
        await swapWaitUntil { self.sources.systemAudio.isRunning }

        hear("Before the pause.", seconds: 20)
        clock.now += 1
        hear("The far side, before the pause.", on: sources.systemAudio, from: .systemAudio, seconds: 19)
        clock.now += 19
        jarvis.session.pause(.user)
        await swapWaitUntil { !self.sources.systemAudio.isRunning }
        jarvis.session.resume()
        await swapWaitUntil { self.sources.systemAudio.isRunning }
        clock.now += 5
        hear("Before the stop.", seconds: 10)
        clock.now += 10
        jarvis.session.stop(.user)
        await swapWaitUntil { self.transcriptText().contains("Before the stop.") }

        #expect(transcriptText().contains("Before the pause."))
        #expect(transcriptText().contains("The far side, before the pause."))
        #expect(transcriptText().contains("Before the stop."))
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
        await swapWaitUntil { !self.sources.mic.isRunning && !self.sources.roomMic.isRunning }
        #expect(!sources.mic.isRunning && !sources.systemAudio.isRunning && !sources.roomMic.isRunning)

        jarvis.beginHoldCommand()
        await swapWaitUntil { self.sources.mic.isRunning }
        #expect(sources.mic.isRunning)
        clock.now += 5
        sayChunk("Held while stopped.", startingAt: clock.now.addingTimeInterval(-2))
        jarvis.endHoldCommand()
        await swapWaitUntil { !self.sources.mic.isRunning }
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

    // F-H1, DEC-22: a command held while Stopped is acted on (read back, and run on a held yes), and
    // Jarvis stays Stopped.
    @Test func aCommandHeldWhileStoppedIsReadBackAndRunsOnAHeldYes() async throws {
        let jarvis = makeJarvis()
        await jarvis.start()
        jarvis.session.stop(.user)
        await swapWaitUntil { !self.sources.mic.isRunning }

        transcriber.saying = "create a file"
        jarvis.beginHoldCommand()
        await swapWaitUntil { self.sources.mic.isRunning }
        sources.say(speech: 8, silence: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        jarvis.endHoldCommand()
        await swapWaitUntil { self.spoken.contains(SwapCommandRunner.draft) }
        #expect(spoken.contains(SwapCommandRunner.draft))

        transcriber.saying = "yes"
        jarvis.beginHoldCommand()
        await swapWaitUntil { self.sources.mic.isRunning }
        sources.say(speech: 4, silence: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        jarvis.endHoldCommand()
        await swapWaitUntil { self.spoken.contains(SwapCommandRunner.result) }

        #expect(runner.executed == [SwapCommandRunner.draft])
        #expect(jarvis.session.state == .stopped(.user))
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

        let question = try jarvis.askToForgetLastHour()
        #expect(question.text.contains("1 transcript line"))
        try jarvis.forgetLastHour(question)
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

        jarvis.speechStarted()
        await Task.yield()
        sources.say(speech: 8, silence: 8)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(chimes == 0)

        jarvis.speechEnded()
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

    // F-2, DEC-14, DEC-25: launched inside quiet hours, Jarvis is stopped at once: no source runs, so not
    // even one chunk is heard before the first 30 s tick.
    @Test func launchingInsideQuietHoursStartsNoSource() async throws {
        try SettingsStore(paths: paths).save(Settings(quietHours: QuietHours(startMinutes: 10 * 60, endMinutes: 11 * 60)))
        let jarvis = makeJarvis()
        await jarvis.start()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(jarvis.session.state == .stopped(.quietHours))
        #expect(sources.mic.startCalls == 0 && sources.systemAudio.startCalls == 0)
        await jarvis.shutdown()
    }

    // F-2, DEC-25: launched while the screen is locked, Jarvis is stopped at once too.
    @Test func launchingWhileTheScreenIsLockedStartsNoSource() async throws {
        screenLock.isScreenLocked = true
        let jarvis = makeJarvis()
        await jarvis.start()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(jarvis.session.state == .stopped(.screenLock))
        #expect(sources.mic.startCalls == 0 && sources.systemAudio.startCalls == 0)
        await jarvis.shutdown()
    }

    // F-3: a capture stream that is slow to start (ScreenCaptureKit can take 20 s) never blocks the main
    // actor, so the menu stays responsive.
    @Test func aSlowSourceStartNeverBlocksTheMainActor() async throws {
        sources.systemAudio.startDelay = 2
        let jarvis = makeJarvis()
        let began = Date()
        await jarvis.start()
        await swapWaitUntil { self.sources.systemAudio.startCalls > 0 }
        await swapWaitUntil { self.sources.mic.isRunning }

        #expect(Date().timeIntervalSince(began) < 1)
        await jarvis.shutdown()
    }

    // F-5: a second start() changes nothing, and the timer ends once Jarvis is released.
    @Test func startIsIdempotentAndTheTimerEndsWithJarvis() async throws {
        var jarvis: Jarvis? = makeJarvis(tickInterval: 0.02)
        await jarvis?.start()
        let timer = try #require(jarvis?.timer)
        await jarvis?.start()
        #expect(jarvis?.timer == timer)

        weak var released = jarvis
        jarvis = nil
        var ended = false
        Task { await timer.value; ended = true }
        await swapWaitUntil(timeout: 3) { ended && released == nil }
        #expect(released == nil)
        #expect(ended)
        timer.cancel()
    }

    // F-H3, F-7, DEC-5 amended: with speech off nothing is transcribed and the inbox is left alone; once
    // speech is installed (the whisper model finished downloading) capture and the importers start, with
    // no relaunch, and the Engines line names the new engine.
    @Test func speechInstalledAfterLaunchStartsTranscriptionAndTheImporters() async throws {
        let recording = try inboxRecording(recordedAt: clock.now.addingTimeInterval(-3 * 3600), saying: "From the inbox.")
        let jarvis = makeJarvis(speechOff: true)
        await jarvis.start()
        await swapWaitUntil { self.sources.mic.isRunning }
        sayChunk("Not heard yet.")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!transcriptText().contains("Not heard yet."))
        #expect(FileManager.default.fileExists(atPath: recording.path))

        await jarvis.installSpeech(main: transcriber, wakeWord: wake, name: "fake whisper")
        clock.now += 1
        sayChunk("Heard now.")
        await swapWaitUntil { self.transcriptText().contains("Heard now.") }
        await swapWaitUntil { self.transcriptText().contains("From the inbox.") }

        #expect(transcriptText().contains("Heard now."))
        #expect(transcriptText().contains("From the inbox."))
        #expect(jarvis.engines.description.speech == "fake whisper")
        await jarvis.shutdown()
    }

    // F-1, F-7, DEC-26: an inbox recording from the hour in progress does not write that hour's note early;
    // the note is written when the hour ends. A recording from a finished hour re-notes that hour.
    @Test func anImportFromTheCurrentHourWaitsForTheHourToEnd() async throws {
        let jarvis = makeJarvis()
        let current = try inboxRecording(recordedAt: clock.now.addingTimeInterval(-5 * 60), saying: "Inbox: Friday.")
        let earlier = try inboxRecording(recordedAt: clock.now.addingTimeInterval(-2 * 3600), saying: "Inbox: Friday early.")
        await jarvis.start()
        await swapWaitUntil(timeout: 15) {
            !FileManager.default.fileExists(atPath: current.path) && !FileManager.default.fileExists(atPath: earlier.path)
        }
        await swapWaitUntil { self.hourlyNote("2026-10-14-08") != nil }

        #expect(hourlyNote("2026-10-14-08") != nil)
        #expect(hourlyNote("2026-10-14-10") == nil)

        clock.now += 3600
        await jarvis.tick()
        #expect(hourlyNote("2026-10-14-10")?.contains("Decided: ship on Friday.") == true)
        await jarvis.shutdown()
    }
}

extension SwappabilityTests {
    // DEC-30: the menu alert fixes the hour it names; leaving it open shifts nothing.
    @Test func forgetDeletesExactlyTheHourTheQuestionNamed() async throws {
        let jarvis = makeJarvis()
        await jarvis.start()
        await swapWaitUntil { self.sources.mic.isRunning }
        sayChunk("Named in the question.")
        await swapWaitUntil { self.transcriptText().contains("Named in the question.") }
        clock.now += 60

        let question = try jarvis.askToForgetLastHour()
        #expect(question.text.hasPrefix("Delete the last hour, 09:16 to 10:16:"))
        clock.now += 30 * 60
        sayChunk("Said while the alert was open.")
        await swapWaitUntil { self.transcriptText().contains("Said while the alert was open.") }
        try jarvis.forgetLastHour(question)

        #expect(!transcriptText().contains("Named in the question."))
        #expect(transcriptText().contains("Said while the alert was open."))
        await jarvis.shutdown()
    }

    // F-4: a start still running when Quit begins, or one asked for after, never opens the mic.
    @Test func startDoesNothingOnceShutdownHasBegun() async {
        let jarvis = makeJarvis()
        let starting = Task { await jarvis.start() }
        await jarvis.shutdown()
        await starting.value
        #expect(jarvis.session.isStopped)

        await jarvis.start()
        #expect(jarvis.session.isStopped)
        await jarvis.shutdown()
        #expect(sources.mic.startCalls == 0)
        #expect(sources.systemAudio.startCalls == 0)
    }

    // DEC-28: asked once, remembered in settings; after a no, the menu offers the way back in.
    @Test func screenRecordingIsAskedOnceAndADeclineIsShown() async {
        let jarvis = makeJarvis()
        #expect(jarvis.shouldAskForScreenRecording)
        #expect(!jarvis.callAudioNeedsScreenRecording)

        jarvis.recordScreenRecordingAsked()
        #expect(!jarvis.shouldAskForScreenRecording)
        #expect(jarvis.callAudioNeedsScreenRecording)
        #expect(SettingsStore(paths: paths).load().screenRecordingAsked)
        #expect(!makeJarvis().shouldAskForScreenRecording)

        permissions.screenGranted = true
        await jarvis.tick()
        #expect(!jarvis.callAudioNeedsScreenRecording)
    }

    @Test func screenRecordingAlreadyGrantedIsNeverAskedFor() {
        permissions.screenGranted = true
        #expect(!makeJarvis().shouldAskForScreenRecording)
    }

    // DEC-31: a denied microphone is shown, and the line goes once access is back.
    @Test func deniedMicrophoneIsShown() async {
        permissions.micDenied = true
        let jarvis = makeJarvis()
        await jarvis.start()
        #expect(jarvis.microphoneAccessOff)

        permissions.micDenied = false
        await jarvis.tick()
        #expect(!jarvis.microphoneAccessOff)
        await jarvis.shutdown()
    }

    // T-26 F-2, story 22: every memory answer is published from launch, typed or spoken, so the Ask panel
    // shows a spoken answer even if it was never opened before. `onMemoryAnswer` still hears spoken ones.
    @Test func everyMemoryAnswerIsPublishedFromLaunchWithWhetherItWasSpoken() async throws {
        let jarvis = makeJarvis()
        var heard: [MemoryAnswer] = []
        jarvis.onMemoryAnswer = { heard.append($0) }
        #expect(jarvis.lastMemoryAnswer == nil)

        let typed = await jarvis.askMemory("What did we decide about Friday?")
        #expect(jarvis.lastMemoryAnswer == ShownMemoryAnswer(answer: typed, spoken: false))
        #expect(heard.isEmpty)

        await jarvis.start()
        await swapWaitUntil { self.sources.mic.isRunning }
        wake.saying = "Jarvis, what did we decide about Friday"
        transcriber.saying = "Jarvis, what did we decide about Friday"
        await swapWaitUntil {
            if jarvis.lastMemoryAnswer?.spoken != true { self.sources.say(speech: 8, silence: 8) }
            return jarvis.lastMemoryAnswer?.spoken == true
        }
        #expect(jarvis.lastMemoryAnswer?.spoken == true)
        #expect(heard == [jarvis.lastMemoryAnswer?.answer])
        await jarvis.shutdown()
    }

    // T-26 F-1: a note opens from the paths this Jarvis was built with, not the standard ones.
    @Test func noteFileFollowsThePathsJarvisWasBuiltWith() async throws {
        let jarvis = makeJarvis()
        await jarvis.start()
        await swapWaitUntil { self.sources.mic.isRunning }
        sayChunk("We ship the launch on Friday.")
        await swapWaitUntil { self.transcriptText().contains("We ship the launch on Friday.") }
        clock.now += 3600
        await jarvis.tick()

        #expect(jarvis.noteFile(id: "2026-10-14-10") == paths.notesHourly.appending(path: "2026-10-14-10.md"))
        #expect(jarvis.noteFile(id: "2026-10-14-09") == nil)
        await jarvis.shutdown()
    }

    // T-27 F-3: a sentence whose finish never arrives mutes the wake word only until the timeout.
    @Test func aLostSpeechFinishUnmutesTheWakeWordAtTheNextTickPastTheTimeout() async {
        let jarvis = makeJarvis()
        jarvis.speechStarted()
        #expect(jarvis.isSpeaking)
        clock.now += SpeakingTracker.timeout - 1
        await jarvis.tick()
        #expect(jarvis.isSpeaking)
        clock.now += 1
        await jarvis.tick()
        #expect(!jarvis.isSpeaking)
    }

    // T-27 F-1/F-2, DEC-33: the stem trigger is off by default. Once chosen it is active only while Jarvis
    // listens or is paused, never Stopped, in quiet hours or locked; the choice is saved with the other keys.
    @Test func theStemTriggerIsActiveOnlyWhenChosenAndListeningOrPaused() async throws {
        try SettingsStore(paths: paths).save(Settings(allowedTools: ["Read"], screenRecordingAsked: true))
        let jarvis = makeJarvis()
        await jarvis.start()
        #expect(!jarvis.stemTriggerChosen && !jarvis.stemTriggerActive)

        try jarvis.setStemTrigger(true)
        #expect(jarvis.stemTriggerChosen && jarvis.stemTriggerActive)
        let saved = SettingsStore(paths: paths).load()
        #expect(saved.stemTrigger && saved.allowedTools == ["Read"] && saved.screenRecordingAsked)
        #expect(makeJarvis().stemTriggerChosen)

        jarvis.session.pause(.user)
        await swapWaitUntil { jarvis.session.state == .paused(.user) }
        await Task.yield()
        #expect(jarvis.stemTriggerActive)
        for stop in [StopReason.user, .quietHours, .screenLock] {
            jarvis.session.resume()
            await swapWaitUntil { jarvis.stemTriggerActive }
            jarvis.session.stop(stop)
            await swapWaitUntil { !jarvis.stemTriggerActive }
            #expect(!jarvis.stemTriggerActive, "stopped by \(stop)")
        }
        jarvis.session.resume()
        await swapWaitUntil { jarvis.stemTriggerActive }
        try jarvis.setStemTrigger(false)
        #expect(!jarvis.stemTriggerActive)
        #expect(!SettingsStore(paths: paths).load().stemTrigger)
        await jarvis.shutdown()
    }

    // DEC-33: while the stem trigger is not active, a play/pause event starts no command.
    @Test func aSqueezeStartsACommandOnlyWhileTheStemTriggerIsActive() async throws {
        let jarvis = makeJarvis()
        await jarvis.start()
        await swapWaitUntil { self.sources.mic.isRunning }
        transcriber.saying = "create a file"

        jarvis.stemPressed()
        await swapWaitUntil(timeout: 2) {
            if !self.spoken.contains(SwapCommandRunner.draft) { self.sources.say(speech: 8, silence: 8) }
            return self.spoken.contains(SwapCommandRunner.draft)
        }
        #expect(!spoken.contains(SwapCommandRunner.draft))

        try jarvis.setStemTrigger(true)
        jarvis.stemPressed()
        await swapWaitUntil {
            if !self.spoken.contains(SwapCommandRunner.draft) { self.sources.say(speech: 8, silence: 8) }
            return self.spoken.contains(SwapCommandRunner.draft)
        }
        #expect(spoken.contains(SwapCommandRunner.draft))
        await jarvis.shutdown()
    }

    // T-27 F-5, DEC-31: an Option-Space the app could not register is shown, not dropped.
    @Test func aHoldKeyThatCouldNotBeRegisteredIsShown() {
        let jarvis = makeJarvis()
        #expect(!jarvis.holdKeyUnavailable)
        jarvis.reportHoldKeyUnavailable()
        #expect(jarvis.holdKeyUnavailable)
    }

    // F-5, DEC-16: Resume from the menu after the headset left says what voice resume says.
    @Test func menuResumeAfterALostHeadsetSaysItUsesTheMacBookMic() async {
        let jarvis = makeJarvis()
        await jarvis.start()
        jarvis.session.handle(.inputLost(InputDevice(name: "AirPods Pro", isBluetoothHeadset: true)))
        #expect(jarvis.session.state == .paused(.routeLost))

        jarvis.chooseTopMenuItem()
        #expect(jarvis.session.state == .listening)
        #expect(spoken == ["Listening through the MacBook mic."])
        jarvis.chooseTopMenuItem()
        #expect(jarvis.session.state == .paused(.user))
        #expect(spoken.count == 1)
        await jarvis.shutdown()
    }
}

// MARK: - Fakes

/// What macOS has granted, as the test says; no real authorization is ever read.
final class SwapPermissions {
    var micDenied = false
    var screenGranted = false
    var status: PermissionStatus {
        PermissionStatus(microphoneDenied: { [unowned self] in micDenied },
                         screenRecordingGranted: { [unowned self] in screenGranted })
    }
}

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

/// A capture stream the test drives. Started and stopped off the main actor, so its state is locked.
final class FakeSource: AudioSourceStream, @unchecked Sendable {
    private let lock = NSLock()
    private var _startError: AudioError?
    private var _startDelay: TimeInterval = 0
    private var _isRunning = false
    private var _startCalls = 0
    private var onChunk: ((AudioChunk) -> Void)?
    /// The chunk still being recorded, handed over by `cut` or `stop` like `MicSource`'s partial chunk.
    private var partial: AudioChunk?

    var startError: AudioError? {
        get { lock.withLock { _startError } }
        set { lock.withLock { _startError = newValue } }
    }
    /// How long `start` blocks, as `SystemAudioSource.start` does on ScreenCaptureKit.
    var startDelay: TimeInterval {
        get { lock.withLock { _startDelay } }
        set { lock.withLock { _startDelay = newValue } }
    }
    var isRunning: Bool { lock.withLock { _isRunning } }
    var startCalls: Int { lock.withLock { _startCalls } }

    func start(onChunk: @escaping (AudioChunk) -> Void) throws {
        let delay = lock.withLock { _startCalls += 1; return _startDelay }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        try lock.withLock {
            if let _startError { throw _startError }
            _isRunning = true
            self.onChunk = onChunk
        }
    }

    func stop() {
        cut()
        lock.withLock {
            _isRunning = false
            onChunk = nil
        }
    }

    func cut() {
        let (deliver, chunk) = lock.withLock { () -> (((AudioChunk) -> Void)?, AudioChunk?) in
            defer { partial = nil }
            return (onChunk, partial)
        }
        if let chunk { deliver?(chunk) }
    }

    /// Delivers `chunk` as the live source would, only while running.
    func emit(_ chunk: AudioChunk) { lock.withLock { onChunk }?(chunk) }

    /// Holds `chunk` as the partial chunk being recorded, only while running.
    func hear(_ chunk: AudioChunk) { lock.withLock { if _isRunning { partial = chunk } } }
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

final class SwapScreenLock: ScreenLockObserving, ScreenLockState {
    var onLock: (() -> Void)?
    var onUnlock: (() -> Void)?
    var isScreenLocked = false
}

final class SwapSleepGuard: SleepGuard {
    func hold() {}
    func release() {}
}
