import AVFoundation
import Combine
import Foundation

/// The one entry point the menu-bar app drives: assembles every JarvisCore piece, runs the timers and
/// routes audio by the listening session's state. Thin on purpose: every rule lives in a component.
/// Engines come in through `Engines` and are only ever reached through the four protocols (D-4).
@MainActor
public final class Jarvis: ObservableObject {
    public let session: ListeningSession
    /// The engines in use. The speech pair can change once after launch, when whisper's model finishes
    /// downloading (DEC-5 amended); the rest stay as chosen at launch.
    @Published public private(set) var engines: Engines
    /// Called with every sentence Jarvis says (read-backs, results, answers). The app sets it (T-27).
    public var speak: (String) -> Void = { _ in }
    /// The wake word was heard.
    public var onChime: () -> Void = {}
    /// A spoken memory question was answered. The Ask panel reads `lastMemoryAnswer` instead.
    public var onMemoryAnswer: (MemoryAnswer) -> Void = { _ in }
    /// The latest memory answer since launch, typed or spoken, for the Ask panel (story 22: spoken and shown).
    @Published public private(set) var lastMemoryAnswer: ShownMemoryAnswer?
    /// Jarvis is saying something, so the wake word is muted (D-8). Driven by `speechStarted`/`speechEnded`.
    @Published public private(set) var isSpeaking = false
    /// The user turned on the experimental AirPods stem squeeze in Settings (DEC-33).
    @Published public private(set) var stemTriggerChosen: Bool
    /// The stem squeeze may listen now: chosen, and Jarvis is listening or paused, never Stopped, in quiet
    /// hours or locked (DEC-33). The app plays its silence and holds Now Playing only while this is true.
    @Published public private(set) var stemTriggerActive = false
    /// The app could not register the Option-Space hold, so it does nothing (shown like DEC-31's mic line).
    @Published public private(set) var holdKeyUnavailable = false
    @Published public private(set) var voiceMemosNeedFullDiskAccess = false
    /// macOS has refused the microphone, so nothing is heard whatever the icon says (DEC-31).
    @Published public private(set) var microphoneAccessOff = false
    /// The mic stream's own word on whether it is recording, so the menu never says "Listening via …"
    /// while the engine is down (J-007).
    @Published public private(set) var micHealth: MicHealth = .ok
    /// The same for Meeting mode's room mic (J-008).
    @Published public private(set) var roomMicHealth: MicHealth = .ok
    /// Screen Recording was asked for and not granted: call audio is off (DEC-28).
    @Published public private(set) var callAudioNeedsScreenRecording = false
    /// 0…1 while the whisper `small` model downloads in the background; `nil` otherwise.
    @Published public private(set) var modelDownloadProgress: Double?

    private let paths: JarvisPaths
    private let settings: SettingsStore
    private let permissions: PermissionStatus
    private let clock: any TimeSource
    private let screenLock: any ScreenLockObserving
    private let routes: any RouteEventSource
    private let speech: SpeechSlot
    private let mic: SourceDriver
    private let systemAudio: SourceDriver
    private let roomMic: SourceDriver
    private let notes: NoteStore
    private let index: NoteIndex
    private let pipeline: CapturePipeline
    private let hourlyNotes: HourlyNoteScheduler
    private let maintenance: LaunchMaintenance
    private let search: MemorySearch
    private let forget: ForgetLastHour
    /// DEC-47: what was said to Jarvis, kept like transcripts; the router writes it.
    private let commandLog: CommandLog
    private let wakeWord: WakeWordListener
    private let inbox: InboxImporter
    private let voiceMemos: VoiceMemosImporter
    private let tickInterval: TimeInterval
    private lazy var commands = CommandSession(runner: { [engines] in engines.commandRunner }, clock: clock,
                                               speak: { [unowned self] in say($0) })
    private lazy var router = VoiceControlRouter(session: session, search: search, forget: forget,
                                                 commands: commands, speak: { [unowned self] in say($0) },
                                                 onAnswer: { [unowned self] in
                                                     lastMemoryAnswer = ShownMemoryAnswer(answer: $0, spoken: true)
                                                     onMemoryAnswer($0)
                                                 }, clock: clock, commandLog: commandLog)
    private var started = false
    /// Set first thing by `shutdown`: a `start` still under way stops where it is (F-4).
    private var shuttingDown = false
    private var importersStarted = false
    private var wakeWordOn = false
    private var holding = false
    /// Set by a hold, so the command it captures routes even while Stopped (DEC-22). Ceiling: a hold that
    /// captures nothing leaves it set, and the next wake-word command is then routed as a held one.
    private var heldCommandPending = false
    private var speaking = SpeakingTracker()
    private(set) var timer: Task<Void, Never>?
    private var lastMaintenance = Date.distantPast
    private var servers: [WhisperServerProcess] = []
    private var serverStarts: [Task<Void, Never>] = []
    private var subscriptions: Set<AnyCancellable> = []

    /// `tickInterval` is the timer's period, 30 s; tests shorten it.
    public init(paths: JarvisPaths, engines: Engines, settings: SettingsStore, clock: any TimeSource,
                sources: any SourceFactory, screenLock: any ScreenLockObserving, sleepGuard: any SleepGuard,
                routes: any RouteEventSource, voiceMemos locator: @escaping () -> VoiceMemosAccess,
                permissions: PermissionStatus, tickInterval: TimeInterval = 30) {
        self.paths = paths
        self.settings = settings
        self.permissions = permissions
        self.engines = engines
        self.clock = clock
        self.screenLock = screenLock
        self.routes = routes
        self.tickInterval = tickInterval
        stemTriggerChosen = settings.load().stemTrigger
        session = ListeningSession(clock: clock, sleepGuard: sleepGuard,
                                   quietHoursEnd: { settings.load().quietHours?.end(of: $0, calendar: .current) })
        let (mic, frames) = sources.makeMic()
        self.mic = SourceDriver(mic, label: "jarvis.drive.mic")
        systemAudio = SourceDriver(sources.makeSystemAudio(), label: "jarvis.drive.system-audio")
        let room = sources.makeRoomMic()
        roomMic = SourceDriver(room, label: "jarvis.drive.room-mic")
        // DEC-5 amended: speech is read per use, so a transcriber installed after launch is used at once.
        let speech = SpeechSlot(main: engines.transcriber, wake: engines.wakeWordTranscriber)
        self.speech = speech

        let transcripts = TranscriptStore(paths: paths)
        let notes = NoteStore(paths: paths)
        let prompts = PromptStore(paths: paths)
        let writer = { engines.noteWriter }
        // DEC-12: one record of forgotten windows, shared by everything that writes lines or notes.
        let forgotten = ForgottenWindows(paths: paths)
        // DEC-8: the index is keyed by the search name on the Engines line.
        let index = NoteIndex(paths: paths, embedder: engines.embedder, embedderID: engines.description.search)
        index.attach(to: notes)
        let pipeline = CapturePipeline(transcriber: { speech.main }, store: transcripts, forgotten: forgotten)
        let hourlyNotes = HourlyNoteScheduler(transcripts: transcripts, session: session, writer: writer,
                                              prompts: prompts, notes: notes, forgotten: forgotten)
        self.notes = notes
        self.index = index
        self.pipeline = pipeline
        self.hourlyNotes = hourlyNotes
        let commandLog = CommandLog(paths: paths)
        self.commandLog = commandLog
        maintenance = LaunchMaintenance(transcripts: transcripts,
                                        rollups: RollupScheduler(notes: notes, writer: writer, prompts: prompts),
                                        commandLog: commandLog)
        search = MemorySearch(index: index, notes: notes, writer: writer, prompts: prompts)
        forget = ForgetLastHour(transcripts: transcripts, notes: notes, index: index, forgotten: forgotten,
                                commandLog: commandLog)
        wakeWord = WakeWordListener(
            mic: frames, wakeWordTranscriber: { speech.wake },
            capture: CommandCapture(buffer: RollingAudioBuffer(seconds: 8), transcriber: { speech.main },
                                    gate: SilenceGate(), clock: clock))

        // DEC-26: the scheduler decides which hours an import notes again.
        let coordinator = ImportCoordinator(pipeline: pipeline) { period in
            do { try await hourlyNotes.renote(touching: period, now: clock.now) } catch {
                Log.notes.error("Re-noting an import failed: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
            }
        }
        inbox = InboxImporter(paths: paths, coordinator: coordinator)
        voiceMemos = VoiceMemosImporter(locator: locator, coordinator: coordinator, ledger: ImportLedger(paths: paths),
                                        paths: paths)

        (mic as? any ReportsMicHealth)?.onHealth = { [weak self] health in
            Task { @MainActor in self?.micHealth = health }
        }
        (room as? any ReportsMicHealth)?.onHealth = { [weak self] health in
            Task { @MainActor in self?.roomMicHealth = health }
        }
        // J-009: a room mic that stopped itself is tried again at once; a route change tries it again later.
        (room as? any StopsItself)?.onStopped = { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        for driver in [self.mic, systemAudio, roomMic] {
            driver.onChunk = { [weak self] chunk, listening in
                Task { @MainActor in await self?.store(chunk, heardWhileListening: listening) }
            }
        }
        wakeWord.onDetected = { [unowned self] in
            Log.command.info("Wake word heard")
            onChime()
        }
        wakeWord.onCommand = { [unowned self] text in
            let held = heldCommandPending
            heldCommandPending = false
            Task { held ? await router.handleHeld(text) : await router.handle(text) }
        }
        screenLock.onLock = { [weak self] in Task { @MainActor in self?.session.screenLocked() } }
        screenLock.onUnlock = { [weak self] in Task { @MainActor in self?.session.screenUnlocked() } }
        routes.onEvent = { [weak self] event in Task { @MainActor in self?.routeChanged(event) } }
        voiceMemos.$needsFullDiskAccess.sink { [weak self] in self?.voiceMemosNeedFullDiskAccess = $0 }
            .store(in: &subscriptions)
        // `@Published` announces a change before it lands: the cut comes first, while the state is still
        // the old one, and the sources follow one hop later.
        session.$state.sink { [weak self] in self?.cutIfListeningChanges(to: $0) }.store(in: &subscriptions)
        let follow: (Any) -> Void = { [weak self] _ in Task { @MainActor in self?.follow() } }
        session.$state.sink(receiveValue: follow).store(in: &subscriptions)
        session.$modes.sink(receiveValue: follow).store(in: &subscriptions)
        commands.$phase.sink(receiveValue: follow).store(in: &subscriptions)
        $isSpeaking.sink(receiveValue: follow).store(in: &subscriptions)
    }

    /// This Mac's engines and devices. Whisper servers start in the background; until one answers, its
    /// chunks fail and are dropped. With whisper.cpp installed but no model, `small` downloads in the
    /// background, and speech starts as soon as it is there, without a relaunch (DEC-5 amended).
    public static func live() async throws -> Jarvis {
        let paths = JarvisPaths.standard
        try paths.adoptLegacyData(from: JarvisPaths.legacyRoot)
        try paths.ensureLayout()
        let settings = SettingsStore(paths: paths)
        let locales = Locale.preferredLanguages.map(Locale.init(identifier:))
        let engines = EngineSelector.select(await EngineProbes.live(paths: paths, preferredLocales: locales),
                                            settings: settings.load)
        let clock = SystemClock()
        let jarvis = Jarvis(paths: paths, engines: engines, settings: settings, clock: clock,
                            sources: LiveSourceFactory(clock: clock), screenLock: DistributedScreenLockObserver(),
                            sleepGuard: IOKitSleepGuard(), routes: AudioRouteMonitor(),
                            voiceMemos: { VoiceMemosLocator.probe() }, permissions: .live)
        jarvis.startServers(of: [engines.transcriber, engines.wakeWordTranscriber])
        let install = WhisperInstall.locate()
        if engines.transcriber == nil, (install.server ?? install.cli) != nil {
            jarvis.modelDownloadProgress = 0
            Task { [weak jarvis] in
                let model: URL?
                do {
                    model = try await WhisperModelDownloader().ensureSmall(in: paths.models) { progress in
                        Task { @MainActor in jarvis?.modelDownloadProgress = progress }
                    }
                } catch {
                    Log.transcribe.error("Whisper model download failed: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
                    model = nil
                }
                jarvis?.modelDownloadProgress = nil
                guard model != nil else { return }
                // Only the speech pair is taken; the rest of this second selection is discarded unstarted.
                let found = EngineSelector.select(await EngineProbes.live(paths: paths, preferredLocales: locales),
                                                  settings: settings.load)
                guard let main = found.transcriber, let wake = found.wakeWordTranscriber else { return }
                await jarvis?.installSpeech(main: main, wakeWord: wake, name: found.description.speech)
            }
        }
        return jarvis
    }

    public var notesAvailable: Bool { engines.noteWriter != nil }

    /// The menu's status line: the session's, unless it is listening and the mic is not recording (J-007),
    /// with a note when Meeting mode's room mic is not recording (J-008).
    public var statusLine: String {
        guard session.state == .listening else { return session.statusLine }
        switch micHealth {
        case .ok: break
        case .reconnecting: return "Reconnecting mic…"
        case .unavailable: return "Mic not recording: reconnect it or choose another input"
        }
        guard session.modes.meetingMode else { return session.statusLine }
        switch roomMicHealth {
        case .ok: return session.statusLine
        case .reconnecting: return session.statusLine + " · reconnecting room mic…"
        case .unavailable: return session.statusLine + " · room mic not recording"
        }
    }
    public var openNotesURL: URL { paths.notesHourly.deletingLastPathComponent() }

    /// Lays out the data home, runs maintenance, refreshes the index, starts listening (stopped at once in
    /// quiet hours or with the screen locked, DEC-25) and, once speech exists, the importers; then ticks
    /// every 30 s. A second call does nothing, and nothing after `shutdown` has begun is started.
    public func start() async {
        guard !started, !shuttingDown else { return }
        started = true
        refreshPermissions()
        do { try paths.ensureLayout() } catch {
            Log.store.error("Data folder layout failed: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
        lastMaintenance = clock.now
        await runMaintenance(now: lastMaintenance)
        do { try index.rebuild(from: notes) } catch {
            Log.notes.error("Index rebuild failed: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
        guard !shuttingDown else { return }
        if let input = routes.current { session.handle(.inputChanged(input)) }
        session.start()
        if (screenLock as? any ScreenLockState)?.isScreenLocked == true { session.screenLocked() }
        session.tick(now: clock.now)
        await startImporters()
        guard !shuttingDown else { return }
        timer = Task { [weak self, tickInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(tickInterval * 1_000_000_000))
                guard let self else { return }
                await self.tick()
            }
        }
    }

    /// For tests: whether the wake listener is on, and how many mic frames it has read.
    var wakeWordListening: Bool { wakeWord.isListening }
    var wakeWordFramesTaken: Int { wakeWord.framesTaken }

    /// Returns once every capture driver has run what was asked of it so far, so a chunk heard after this
    /// is tagged with the current listening state. For tests: `cut` hops to each driver's queue.
    func settleCapture() async {
        for driver in [mic, systemAudio, roomMic] { await driver.settle() }
    }

    /// Stops the timer, every source, the importers and the whisper servers. The app calls it at quit.
    /// A server still starting is cancelled and awaited first, so none is launched after this returns;
    /// the servers stop off the main actor, together (each waits up to ~3 s, DEC-10).
    public func shutdown() async {
        shuttingDown = true
        timer?.cancel()
        session.stop(.user)
        follow()
        await inbox.stop()
        await voiceMemos.stop()
        for driver in [mic, systemAudio, roomMic] { await driver.settle() }
        serverStarts.forEach { $0.cancel() }
        for start in serverStarts { await start.value }
        let servers = servers
        await withTaskGroup(of: Void.self) { group in
            for server in servers { group.addTask { server.stop() } }
        }
    }

    /// The 30 s tick. Maintenance comes after the hourly note, so a roll-up includes the hour just written.
    /// Its failures are retried by the next run (T-7), so they are not reported here.
    func tick() async {
        refreshPermissions()
        let now = clock.now
        speaking.expire(now: now)
        publishSpeaking()
        session.tick(now: now)
        commands.tick(now: now)
        do { try await hourlyNotes.tick(now: now) } catch {
            Log.notes.error("Hourly note failed: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
        guard now.timeIntervalSince(lastMaintenance) >= 3600 else { return }
        lastMaintenance = now
        await runMaintenance(now: now)
    }

    /// Maintenance retries its own failures at the next run (T-7); they are only logged here.
    private func runMaintenance(now: Date) async {
        let result = await maintenance.run(now: now)
        if let error = result.purge {
            Log.store.error("Transcript purge failed: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
        for (id, error) in result.rollups {
            Log.notes.error("Roll-up \(id, privacy: .public) failed: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
    }

    /// Speech found after launch (whisper's model finished downloading): capture, the wake word and
    /// commands use it at once, its whisper servers start, and so do the importers. The search embedder
    /// stays as chosen at launch (DEC-5 amended).
    func installSpeech(main: any Transcriber, wakeWord: any Transcriber, name: String) async {
        speech.install(main: main, wake: wakeWord)
        let old = engines
        engines = Engines(transcriber: main, wakeWordTranscriber: wakeWord, noteWriter: old.noteWriter,
                          embedder: old.embedder, commandRunner: old.commandRunner,
                          description: EnginesDescription(speech: name, notes: old.description.notes,
                                                          search: old.description.search))
        startServers(of: [main, wakeWord])
        await startImporters()
    }

    /// A typed question; its answer is also published as `lastMemoryAnswer`.
    public func askMemory(_ question: String) async -> MemoryAnswer {
        let answer = (try? await search.answer(question))
            ?? MemoryAnswer(text: "I couldn't search my notes.", usedNoteIDs: [])
        lastMemoryAnswer = ShownMemoryAnswer(answer: answer, spoken: false)
        return answer
    }

    /// The file of the note with this id, in the notes folder this Jarvis was built with; `nil` if it is gone.
    public func noteFile(id: String) -> URL? { notes.file(id: id) }

    /// The question the menu asks before `forgetLastHour(_:)`, with live counts. The hour it names is
    /// fixed now, so a Delete clicked later removes that hour and no other (DEC-30).
    public func askToForgetLastHour() throws -> ForgetLastHourQuestion {
        let now = clock.now
        return ForgetLastHourQuestion(text: try forget.describe(now: now), now: now)
    }

    @discardableResult
    public func forgetLastHour(_ question: ForgetLastHourQuestion) throws -> ForgetReport {
        try forget.perform(now: question.now)
    }

    /// The menu's top item: the session acts, and a resume after a lost headset is spoken (DEC-16).
    public func chooseTopMenuItem() {
        if let notice = session.chooseTopMenuItem() { say(notice) }
    }

    // MARK: speech

    /// The app calls this as each sentence starts, and `speechEnded` when it finishes or is cancelled.
    public func speechStarted() {
        speaking.begin(now: clock.now)
        publishSpeaking()
    }

    public func speechEnded() {
        speaking.end()
        publishSpeaking()
    }

    /// Every sentence goes out here. An empty one is dropped: it would get no finish to end it.
    private func say(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        speak(text)
    }

    private func publishSpeaking() {
        if speaking.isSpeaking != isSpeaking { isSpeaking = speaking.isSpeaking }
    }

    // MARK: triggers

    /// Saves the Settings choice with the other keys kept (DEC-28) and applies it at once.
    public func setStemTrigger(_ on: Bool) throws {
        var saved = settings.load()
        saved.stemTrigger = on
        try settings.save(saved)
        stemTriggerChosen = on
        follow()
    }

    public func reportHoldKeyUnavailable() { holdKeyUnavailable = true }

    // MARK: permissions

    /// Screen Recording is explained and asked for once, on a launch where it is not granted (DEC-28).
    public var shouldAskForScreenRecording: Bool {
        !settings.load().screenRecordingAsked && !permissions.screenRecordingGranted()
    }

    /// The app calls this once it has asked, whatever the answer.
    public func recordScreenRecordingAsked() {
        var saved = settings.load()
        saved.screenRecordingAsked = true
        do { try settings.save(saved) } catch {
            Log.store.error("Settings save failed: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
        refreshPermissions()
    }

    /// Read at start and every tick, so a permission granted in System Settings clears its line.
    /// Assigned only on a change, so an unchanged tick doesn't redraw the menu.
    private func refreshPermissions() {
        let micOff = permissions.microphoneDenied()
        let callAudioOff = settings.load().screenRecordingAsked && !permissions.screenRecordingGranted()
        if micOff != microphoneAccessOff { microphoneAccessOff = micOff }
        if callAudioOff != callAudioNeedsScreenRecording { callAudioNeedsScreenRecording = callAudioOff }
    }

    /// Works while Stopped too: the mic runs for the hold only, what it hears is not stored, and the
    /// command routes as usual (story 8a, DEC-22).
    public func beginHoldCommand() {
        holding = true
        heldCommandPending = true
        follow()
        wakeWord.beginHold()
    }

    public func endHoldCommand() {
        wakeWord.endHold()
        holding = false
        follow()
    }

    /// A play/pause remote command while the stem trigger is active; ignored otherwise (DEC-33).
    public func stemPressed() {
        guard stemTriggerActive else { return }
        wakeWord.pressToTalk()
    }

    // MARK: engines

    /// With speech off a recording would only be kept and retried for nothing, so the importers wait for it.
    private func startImporters() async {
        guard started, !shuttingDown, !importersStarted, speech.main != nil else { return }
        importersStarted = true
        do { try inbox.start() } catch {
            Log.imports.error("Inbox importer didn't start: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
        do { try await voiceMemos.start() } catch {
            Log.imports.error("Voice Memos importer didn't start: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
        }
    }

    /// Starts the whisper servers behind `transcribers` in the background (EngineSelector creates them
    /// stopped, pidfiles per role, DEC-6). `shutdown` cancels and awaits these starts before stopping them.
    private func startServers(of transcribers: [(any Transcriber)?]) {
        let started = transcribers.compactMap { engine -> WhisperServerProcess? in
            guard let whisper = engine as? WhisperTranscriber, case .server(let server) = whisper.backend else { return nil }
            return server
        }
        guard !started.isEmpty else { return }
        servers += started
        serverStarts.append(Task.detached {
            for server in started where !Task.isCancelled {
                do { try await server.start() } catch {
                    Log.transcribe.error("Whisper server didn't start: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
                }
            }
        })
    }

    // MARK: routing

    /// Runs what the session's state calls for and listens for the reply to a read-back.
    private func follow() {
        mic.run(session.wakeWordActive || holding)
        systemAudio.run(session.storesMemory)
        roomMic.run(session.storesMemory && session.modes.meetingMode)
        let wake = session.wakeWordActive && !isSpeaking
        if wake != wakeWordOn {
            wakeWordOn = wake
            wake ? wakeWord.start() : wakeWord.stop()
        }
        let stem = stemTriggerChosen && !session.isStopped
        if stem != stemTriggerActive { stemTriggerActive = stem }
        listenForReplyIfAwaited()
    }

    /// DEC-24: at every listening boundary (pause, resume, stop, start, quiet hours, lock) each stream
    /// ends its chunk before the new state applies, so every chunk lies wholly inside or outside
    /// listening. The room stream runs only while listening and has no cut, so it stops instead.
    private func cutIfListeningChanges(to next: ListeningState) {
        let listening = next == .listening
        guard listening != session.storesMemory else { return }
        mic.cut(listening: listening)
        systemAudio.cut(listening: listening)
        roomMic.cut(listening: listening, byStopping: true)
    }

    /// The room stream is pinned to the built-in mic, so a route change may have made it redundant: it is
    /// stopped and `follow` starts it again unless it now refuses (DEC-16). The mic needs no restart:
    /// `MicSource` follows the default input itself.
    private func routeChanged(_ event: RouteEvent) {
        session.handle(event)
        roomMic.stop()
        follow()
    }

    /// Stores a chunk only if it was heard while listening (story 25b). The cut at each boundary makes
    /// that true of the whole chunk.
    private func store(_ chunk: AudioChunk, heardWhileListening: Bool) async {
        guard heardWhileListening else { return }
        do { _ = try await pipeline.process(chunk) } catch {
            Log.transcribe.error("""
                A \(chunk.duration, format: .fixed(precision: 1), privacy: .public) s chunk from \(String(describing: chunk.source), privacy: .public) \
                wasn't stored: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)
                """)
        }
    }

    /// Listens for the yes or no after a read-back. Not while Stopped: the mic runs only for a hold
    /// there, so the next hold is the reply (DEC-22). A second call while one listens gets `nil` at once;
    /// the `commands.tick` that follows cancels nothing early, because `CommandSession.tick` cancels a
    /// read-back only once its `replyTimeout` has passed.
    private func listenForReplyIfAwaited() {
        guard case .awaitingConfirmation = commands.phase, !isSpeaking, session.wakeWordActive else { return }
        Task {
            if let reply = await wakeWord.listenForReply() {
                await router.heardReply(reply)
            } else {
                commands.tick(now: clock.now)
            }
        }
    }
}

/// A memory answer and whether it answered a spoken question.
public struct ShownMemoryAnswer: Equatable {
    public let answer: MemoryAnswer
    public let spoken: Bool

    public init(answer: MemoryAnswer, spoken: Bool) {
        self.answer = answer
        self.spoken = spoken
    }
}

/// What `askToForgetLastHour` asked, with the instant that fixes its hour.
public struct ForgetLastHourQuestion {
    public let text: String
    fileprivate let now: Date
}

/// What macOS has granted Jarvis, read without asking for anything or opening a device.
public struct PermissionStatus {
    public var microphoneDenied: () -> Bool
    public var screenRecordingGranted: () -> Bool

    public init(microphoneDenied: @escaping () -> Bool, screenRecordingGranted: @escaping () -> Bool) {
        self.microphoneDenied = microphoneDenied
        self.screenRecordingGranted = screenRecordingGranted
    }

    public static var live: PermissionStatus {
        PermissionStatus(microphoneDenied: { [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio)) },
                         screenRecordingGranted: { SystemAudioSource.isAuthorized })
    }
}

/// The speech engines in use, read by capture, the importers and the wake word from any thread.
private final class SpeechSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var _main: (any Transcriber)?
    private var _wake: (any Transcriber)?

    init(main: (any Transcriber)?, wake: (any Transcriber)?) {
        _main = main
        _wake = wake
    }

    var main: (any Transcriber)? { lock.withLock { _main } }
    var wake: (any Transcriber)? { lock.withLock { _wake } }

    func install(main: any Transcriber, wake: any Transcriber) {
        lock.withLock { _main = main; _wake = wake }
    }
}

/// One capture stream, driven off the main actor: `SystemAudioSource.start` can block for up to 20 s on
/// ScreenCaptureKit (F-3). A serial queue per stream keeps its starts, stops and cuts in the order asked.
/// Each chunk is tagged with whether Jarvis was listening when the stream delivered it.
private final class SourceDriver: @unchecked Sendable {
    /// Set once, before the first `run`; the queue hop orders it before any delivery.
    var onChunk: (AudioChunk, _ heardWhileListening: Bool) -> Void = { _, _ in }

    private let source: any AudioSourceStream
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var wanted = false
    private var applyQueued = false
    private var listening = false

    private let label: String

    init(_ source: any AudioSourceStream, label: String) {
        self.source = source
        self.label = label
        queue = DispatchQueue(label: label)
    }

    /// Starts or stops the stream to match `on`. Only the latest wish is applied, so a slow, failing
    /// start never queues up behind itself; a failed start is tried again at the next call. `start` is a
    /// no-op on a running stream and fails quietly without permission, or when the room mic would
    /// duplicate the input.
    func run(_ on: Bool) {
        let queueApply = lock.withLock { () -> Bool in
            wanted = on
            defer { applyQueued = true }
            return !applyQueued
        }
        guard queueApply else { return }
        queue.async { [self] in
            let on = lock.withLock { () -> Bool in
                applyQueued = false
                return wanted
            }
            if on {
                do { try source.start { [weak self] chunk in self?.deliver(chunk) } } catch AudioError.redundantWithDefaultInput {
                    // Expected: the mic stream records the room then.
                } catch {
                    Log.capture.error("\(label, privacy: .public) didn't start: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
                }
            } else {
                source.stop()
            }
        }
    }

    func stop() { queue.async { [self] in source.stop() } }

    /// Ends the chunk being recorded (through `onChunk`, still tagged with the old state), then
    /// records whether Jarvis now listens.
    func cut(listening now: Bool, byStopping: Bool = false) {
        queue.async { [self] in
            byStopping ? source.stop() : source.cut()
            lock.withLock { listening = now }
        }
    }

    /// Returns once everything asked so far has run.
    func settle() async {
        await withCheckedContinuation { done in queue.async { done.resume() } }
    }

    private func deliver(_ chunk: AudioChunk) {
        onChunk(chunk, lock.withLock { listening })
    }
}
