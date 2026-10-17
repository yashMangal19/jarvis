import Combine
import Foundation

/// The one entry point the menu-bar app drives: assembles every JarvisCore piece, runs the timers and
/// routes audio by the listening session's state. Thin on purpose: every rule lives in a component.
/// Engines come in through `Engines` and are only ever reached through the four protocols (D-4).
@MainActor
public final class Jarvis: ObservableObject {
    public let session: ListeningSession
    public let engines: Engines
    /// Called with every sentence Jarvis says (read-backs, results, answers). The app sets it (T-27).
    public var speak: (String) -> Void = { _ in }
    /// The wake word was heard.
    public var onChime: () -> Void = {}
    /// A spoken memory question was answered, for the Ask panel.
    public var onMemoryAnswer: (MemoryAnswer) -> Void = { _ in }
    /// Set by the app around its own speech; mutes the wake word meanwhile (D-8).
    @Published public var isSpeaking = false
    @Published public private(set) var voiceMemosNeedFullDiskAccess = false
    /// 0…1 while the whisper `small` model downloads in the background; `nil` otherwise.
    @Published public private(set) var modelDownloadProgress: Double?

    private let paths: JarvisPaths
    private let clock: any TimeSource
    private let screenLock: any ScreenLockObserving
    private let routes: any RouteEventSource
    private let mic: any AudioSourceStream
    private let systemAudio: any AudioSourceStream
    private let roomMic: any AudioSourceStream
    private let notes: NoteStore
    private let index: NoteIndex
    private let pipeline: CapturePipeline
    private let hourlyNotes: HourlyNoteScheduler
    private let maintenance: LaunchMaintenance
    private let search: MemorySearch
    private let forget: ForgetLastHour
    private let wakeWord: WakeWordListener
    private let inbox: InboxImporter
    private let voiceMemos: VoiceMemosImporter
    private lazy var commands = CommandSession(runner: { [engines] in engines.commandRunner }, clock: clock,
                                               speak: { [unowned self] in speak($0) })
    private lazy var router = VoiceControlRouter(session: session, search: search, forget: forget,
                                                 commands: commands, speak: { [unowned self] in speak($0) },
                                                 onAnswer: { [unowned self] in onMemoryAnswer($0) }, clock: clock)
    private var wakeWordOn = false
    private var holding = false
    private var timer: Task<Void, Never>?
    private var lastMaintenance = Date.distantPast
    /// Stops the child processes `live()` started.
    private var stopProcesses: () -> Void = {}
    private var subscriptions: Set<AnyCancellable> = []

    public init(paths: JarvisPaths, engines: Engines, settings: SettingsStore, clock: any TimeSource,
                sources: any SourceFactory, screenLock: any ScreenLockObserving, sleepGuard: any SleepGuard,
                routes: any RouteEventSource, voiceMemos locator: @escaping () -> VoiceMemosAccess) {
        self.paths = paths
        self.engines = engines
        self.clock = clock
        self.screenLock = screenLock
        self.routes = routes
        session = ListeningSession(clock: clock, sleepGuard: sleepGuard,
                                   isQuietTime: { settings.load().quietHours?.contains($0, calendar: .current) ?? false })
        let (mic, frames) = sources.makeMic()
        self.mic = mic
        systemAudio = sources.makeSystemAudio()
        roomMic = sources.makeRoomMic()

        let transcripts = TranscriptStore(paths: paths)
        let notes = NoteStore(paths: paths)
        let prompts = PromptStore(paths: paths)
        let writer = { engines.noteWriter }
        // DEC-12: one record of forgotten windows, shared by everything that writes lines or notes.
        let forgotten = ForgottenWindows(paths: paths)
        // DEC-8: the index is keyed by the search name on the Engines line.
        let index = NoteIndex(paths: paths, embedder: engines.embedder, embedderID: engines.description.search)
        index.attach(to: notes)
        let pipeline = CapturePipeline(transcriber: engines.transcriber ?? NoSpeech(), store: transcripts,
                                       forgotten: forgotten)
        let hourlyNotes = HourlyNoteScheduler(transcripts: transcripts, session: session, writer: writer,
                                              prompts: prompts, notes: notes, forgotten: forgotten)
        self.notes = notes
        self.index = index
        self.pipeline = pipeline
        self.hourlyNotes = hourlyNotes
        maintenance = LaunchMaintenance(transcripts: transcripts,
                                        rollups: RollupScheduler(notes: notes, writer: writer, prompts: prompts))
        search = MemorySearch(index: index, notes: notes, writer: writer, prompts: prompts)
        forget = ForgetLastHour(transcripts: transcripts, notes: notes, index: index, forgotten: forgotten)
        wakeWord = WakeWordListener(
            mic: frames, wakeWordTranscriber: { engines.wakeWordTranscriber },
            capture: CommandCapture(buffer: RollingAudioBuffer(seconds: 8), transcriber: { engines.transcriber },
                                    gate: SilenceGate(), clock: clock))

        let coordinator = ImportCoordinator(pipeline: pipeline) { period in
            // Every clock hour the recording touches gets its note written again, now with its lines.
            var hour = Calendar.current.dateInterval(of: .hour, for: period.start)
            while let current = hour, current.start < period.end {
                _ = try? await hourlyNotes.writeNote(for: current)
                hour = Calendar.current.dateInterval(of: .hour, for: current.end)
            }
        }
        inbox = InboxImporter(paths: paths, coordinator: coordinator)
        voiceMemos = VoiceMemosImporter(locator: locator, coordinator: coordinator, ledger: ImportLedger(paths: paths),
                                        paths: paths)

        wakeWord.onDetected = { [unowned self] in onChime() }
        wakeWord.onCommand = { [unowned self] text in Task { await router.handle(text) } }
        screenLock.onLock = { [weak self] in Task { @MainActor in self?.session.screenLocked() } }
        screenLock.onUnlock = { [weak self] in Task { @MainActor in self?.session.screenUnlocked() } }
        routes.onEvent = { [weak self] event in Task { @MainActor in self?.routeChanged(event) } }
        voiceMemos.$needsFullDiskAccess.sink { [weak self] in self?.voiceMemosNeedFullDiskAccess = $0 }
            .store(in: &subscriptions)
        // `@Published` announces a change before it lands, so the sources follow one hop later.
        let follow: (Any) -> Void = { [weak self] _ in Task { @MainActor in self?.follow() } }
        session.$state.sink(receiveValue: follow).store(in: &subscriptions)
        session.$modes.sink(receiveValue: follow).store(in: &subscriptions)
        commands.$phase.sink(receiveValue: follow).store(in: &subscriptions)
        $isSpeaking.sink(receiveValue: follow).store(in: &subscriptions)
    }

    /// This Mac's engines and devices. Whisper servers start in the background; until one answers, its
    /// chunks fail and are dropped. With whisper.cpp installed but no model, `small` downloads in the
    /// background. Ceiling: the engines are chosen once, so speech starts at the next launch after it.
    public static func live() async throws -> Jarvis {
        let paths = JarvisPaths.standard
        try paths.ensureLayout()
        let settings = SettingsStore(paths: paths)
        let probes = await EngineProbes.live(paths: paths,
                                             preferredLocales: Locale.preferredLanguages.map(Locale.init(identifier:)))
        let engines = EngineSelector.select(probes, settings: settings.load)
        let clock = SystemClock()
        let jarvis = Jarvis(paths: paths, engines: engines, settings: settings, clock: clock,
                            sources: LiveSourceFactory(clock: clock), screenLock: DistributedScreenLockObserver(),
                            sleepGuard: IOKitSleepGuard(), routes: AudioRouteMonitor(),
                            voiceMemos: { VoiceMemosLocator.probe() })
        // EngineSelector creates the servers stopped (pidfiles per role, DEC-6); `stop` waits boundedly (DEC-10).
        let servers = [engines.transcriber, engines.wakeWordTranscriber].compactMap { engine -> WhisperServerProcess? in
            guard let whisper = engine as? WhisperTranscriber, case .server(let server) = whisper.backend else { return nil }
            return server
        }
        jarvis.stopProcesses = { servers.forEach { $0.stop() } }
        Task { for server in servers { try? await server.start() } }
        let install = WhisperInstall.locate()
        if engines.transcriber == nil, (install.server ?? install.cli) != nil {
            jarvis.modelDownloadProgress = 0
            Task { [weak jarvis] in
                _ = try? await WhisperModelDownloader().ensureSmall(in: paths.models) { progress in
                    Task { @MainActor in jarvis?.modelDownloadProgress = progress }
                }
                jarvis?.modelDownloadProgress = nil
            }
        }
        return jarvis
    }

    public var notesAvailable: Bool { engines.noteWriter != nil }
    public var openNotesURL: URL { paths.notesHourly.deletingLastPathComponent() }

    /// Lays out `~/Jarvis`, runs maintenance, refreshes the index, starts listening and the importers,
    /// then ticks every 30 s.
    public func start() async {
        try? paths.ensureLayout()
        lastMaintenance = clock.now
        await maintenance.run(now: lastMaintenance)
        try? index.rebuild(from: notes)
        if let input = routes.current { session.handle(.inputChanged(input)) }
        session.start()
        // With speech off an import would transcribe nothing and still delete the recording.
        if engines.transcriber != nil {
            try? inbox.start()
            try? await voiceMemos.start()
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.tick()
            }
        }
    }

    /// Stops the timer, every source, the importers and the whisper servers. The app calls it at quit.
    public func shutdown() async {
        timer?.cancel()
        session.stop(.user)
        follow()
        await inbox.stop()
        await voiceMemos.stop()
        stopProcesses()
    }

    /// The 30 s tick. Maintenance comes after the hourly note, so a roll-up includes the hour just written.
    /// Its failures are retried by the next run (T-7), so they are not reported here.
    func tick() async {
        let now = clock.now
        session.tick(now: now)
        commands.tick(now: now)
        try? await hourlyNotes.tick(now: now)
        guard now.timeIntervalSince(lastMaintenance) >= 3600 else { return }
        lastMaintenance = now
        await maintenance.run(now: now)
    }

    public func askMemory(_ question: String) async -> MemoryAnswer {
        do { return try await search.answer(question) } catch {
            return MemoryAnswer(text: "I couldn't search my notes.", usedNoteIDs: [])
        }
    }

    /// The question the menu asks before `forgetLastHour()`, with live counts.
    public func forgetLastHourDescription() throws -> String { try forget.describe(now: clock.now) }

    @discardableResult
    public func forgetLastHour() throws -> ForgetReport { try forget.perform(now: clock.now) }

    /// Works while Stopped too: the mic runs for the hold only, and what it hears is not stored (story 8a).
    public func beginHoldCommand() {
        holding = true
        follow()
        wakeWord.beginHold()
    }

    public func endHoldCommand() {
        wakeWord.endHold()
        holding = false
        follow()
    }

    public func stemPressed() { wakeWord.pressToTalk() }

    // MARK: routing

    /// Runs what the session's state calls for and listens for the reply to a read-back.
    private func follow() {
        run(mic, session.wakeWordActive || holding)
        run(systemAudio, session.storesMemory)
        run(roomMic, session.storesMemory && session.modes.meetingMode)
        let wake = session.wakeWordActive && !isSpeaking
        if wake != wakeWordOn {
            wakeWordOn = wake
            wake ? wakeWord.start() : wakeWord.stop()
        }
        listenForReplyIfAwaited()
    }

    /// The room stream is pinned to the built-in mic, so a route change may have made it redundant: it is
    /// stopped and `follow` starts it again unless it now refuses (DEC-16). The mic needs no restart:
    /// `MicSource` follows the default input itself.
    private func routeChanged(_ event: RouteEvent) {
        session.handle(event)
        roomMic.stop()
        follow()
    }

    /// `start` is a no-op on a running source and fails quietly without permission, or when the room mic
    /// would duplicate the input.
    private func run(_ source: any AudioSourceStream, _ running: Bool) {
        guard running else { return source.stop() }
        try? source.start { [weak self] chunk in Task { @MainActor in await self?.store(chunk) } }
    }

    /// Stores a chunk only if all of it was heard while listening: one that overlaps a pause or stop is
    /// dropped whole (story 25b). Ceiling: up to 30 s of listening speech is lost at each such boundary,
    /// because `MicSource` cannot cut its chunk there.
    private func store(_ chunk: AudioChunk) async {
        let heard = DateInterval(start: chunk.start, duration: chunk.duration)
        guard session.storesMemory, session.gaps(in: heard).isEmpty else { return }
        _ = try? await pipeline.process(chunk)
    }

    /// A second call while one listens gets `nil` at once, and the tick it causes changes nothing.
    private func listenForReplyIfAwaited() {
        guard case .awaitingConfirmation = commands.phase, !isSpeaking else { return }
        Task {
            if let reply = await wakeWord.listenForReply() {
                await router.heardReply(reply)
            } else {
                commands.tick(now: clock.now)
            }
        }
    }
}

/// `CapturePipeline` takes a transcriber rather than D-4's optional one; with speech off, nothing is heard.
private struct NoSpeech: Transcriber {
    func transcribe(_ chunk: AudioChunk) async throws -> String { "" }
}
