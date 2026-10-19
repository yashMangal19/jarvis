import AVFAudio
import Foundation
import Testing
@testable import JarvisCore

@Suite(.serialized) final class WhisperTranscriberTests {
    /// Every temp directory a test creates; removed when the test's suite instance goes away.
    private var tempDirs: [URL] = []
    deinit { tempDirs.forEach { try? FileManager.default.removeItem(at: $0) } }

    private func tempDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// An executable `/bin/sh` script called `name` in a fresh temp directory.
    private func fakeExecutable(_ name: String, _ body: String) throws -> URL {
        let binary = try tempDir("fake").appending(path: name)
        try "#!/bin/sh\n\(body)\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    // MARK: WAVWriter

    @Test func wavHeaderSays16kMono16BitAndDataMatchesSampleCount() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "wavtest-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let chunk = AudioChunk(samples: [Float](repeating: 0.25, count: 16_000), sampleRate: 16_000,
                               start: Date(), source: .mic)

        try WAVWriter.write(chunk, to: url)

        let data = try Data(contentsOf: url)
        func u32(_ at: Int) -> UInt32 { data[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        func u16(_ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(u16(20) == 1)        // PCM
        #expect(u16(22) == 1)        // mono
        #expect(u32(24) == 16_000)   // sample rate
        #expect(u16(34) == 16)       // bits per sample
        #expect(u32(40) == 32_000)   // data bytes: 16 000 samples x 2 bytes
        #expect(data.count == 44 + 32_000)
    }

    // MARK: .cli backend

    /// A fake whisper-cli: records its argv in `args.txt`, prints `output`, exits with `status`.
    private func fakeCLI(output: String, status: Int32) throws -> (binary: URL, argsFile: URL) {
        let argsFile = try tempDir("fakecli").appending(path: "args.txt")
        let binary = try fakeExecutable("whisper-cli", """
        printf '%s\\n' "$@" > '\(argsFile.path)'
        printf '%s' '\(output)'
        exit \(status)
        """)
        return (binary, argsFile)
    }

    /// The `-f <wav>` path the fake CLI was given.
    private func wavPath(in argsFile: URL) throws -> String {
        let args = try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        return try #require(args.firstIndex(of: "-f").map { args[$0 + 1] })
    }

    private let oneSecond = AudioChunk(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000,
                                       start: Date(), source: .mic)

    @Test func cliBackendReturnsCleanedStdoutAndRemovesTheTempWAV() async throws {
        let fake = try fakeCLI(output: " [BLANK_AUDIO]\n hello world\n", status: 0)
        let model = URL(filePath: "/models/ggml-small.bin")
        let transcriber = WhisperTranscriber(backend: .cli(binary: fake.binary, model: model))

        let text = try await transcriber.transcribe(oneSecond)

        #expect(text == "hello world")
        let args = try String(contentsOf: fake.argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(Array(args.prefix(2)) == ["-m", model.path])
        #expect(Array(args.suffix(4)) == ["-l", "auto", "-nt", "-np"])
        let wav = try wavPath(in: fake.argsFile)
        #expect(URL(filePath: wav).lastPathComponent.hasPrefix("jarvis-"))
        #expect(!FileManager.default.fileExists(atPath: wav))
    }

    @Test func cliBackendThrowsOnExit1AndStillRemovesTheTempWAV() async throws {
        let fake = try fakeCLI(output: "boom", status: 1)
        let transcriber = WhisperTranscriber(backend: .cli(binary: fake.binary, model: URL(filePath: "/m.bin")))

        await #expect(throws: WhisperError.self) { try await transcriber.transcribe(oneSecond) }

        #expect(!FileManager.default.fileExists(atPath: try wavPath(in: fake.argsFile)))
    }

    // Gate repair: a child that ignores SIGTERM is killed after a grace period rather than waited on.
    @Test(arguments: ["", "trap '' TERM"])
    func cancellingACLITranscribeTerminatesTheChildPromptly(ignoringSIGTERM trap: String) async throws {
        let argsFile = try tempDir("fakecli").appending(path: "args.txt")
        let slow = try fakeExecutable("whisper-cli", """
        \(trap)
        printf '%s\\n' "$@" > '\(argsFile.path)'
        exec /bin/sleep 30
        """)
        let transcriber = WhisperTranscriber(backend: .cli(binary: slow, model: URL(filePath: "/m.bin")))
        let chunk = oneSecond
        let task = Task { try await transcriber.transcribe(chunk) }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: argsFile.path) {
            try await Task.sleep(nanoseconds: 100_000_000)     // until the child is running
        }

        let cancelledAt = Date()
        task.cancel()
        let result = await task.result

        #expect(Date().timeIntervalSince(cancelledAt) < 5)
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: try wavPath(in: argsFile)))
    }

    // MARK: .server backend

    @Test func serverBackendPostsMultipartAndReturnsCleanedText() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubInference.self]
        StubInference.reply = " [BLANK_AUDIO]\n hola mundo\n"
        let server = WhisperServerProcess(binary: URL(filePath: "/bin/false"), model: URL(filePath: "/m.bin"),
                                          port: 17_171)
        let transcriber = WhisperTranscriber(backend: .server(server), session: URLSession(configuration: config))

        let text = try await transcriber.transcribe(oneSecond)

        #expect(text == "hola mundo")
        let request = try #require(StubInference.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://127.0.0.1:17171/inference")
        let body = String(decoding: StubInference.lastBody, as: UTF8.self)
        #expect(body.contains("name=\"language\"\r\n\r\nauto\r\n"))
        #expect(body.contains("name=\"response_format\"\r\n\r\ntext\r\n"))
        #expect(body.contains("name=\"file\"; filename=\"jarvis-"))
        #expect(body.contains("RIFF"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        let sent = try #require(body.firstMatch(of: #/filename="(jarvis-[^"]+)"/#)?.output.1)
        #expect(!leftovers.contains(String(sent)))
    }

    // F-1: ambient mic audio never reaches the disk on the server path — the WAV is posted from memory.
    @Test func serverBackendWritesNoTempWAV() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubInference.self]
        StubInference.reply = "hola"
        let server = WhisperServerProcess(binary: URL(filePath: "/bin/false"), model: URL(filePath: "/m.bin"),
                                          port: 17_171)
        let transcriber = WhisperTranscriber(backend: .server(server), session: URLSession(configuration: config))
        let before = StubInference.tempWAVs()

        _ = try await transcriber.transcribe(oneSecond)

        #expect(StubInference.tempWAVsDuringRequest == before)
    }

    // MARK: WhisperInstall

    private func folder(with files: [String], executable: Bool = false) throws -> URL {
        let dir = try tempDir("wi")
        for name in files {
            let file = dir.appending(path: name)
            try Data("x".utf8).write(to: file)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        }
        return dir
    }

    @Test func locateTakesTheFirstExecutableOfEachNameAlongTheSearchPath() throws {
        let first = try folder(with: ["whisper-cli"], executable: true)
        let second = try folder(with: ["whisper-server", "whisper-cli"], executable: true)
        let notExecutable = try folder(with: ["whisper-server"])

        let install = WhisperInstall.locate(searching: [notExecutable, first, second])

        #expect(install.cli?.path == first.appending(path: "whisper-cli").path)
        #expect(install.server?.path == second.appending(path: "whisper-server").path)
        #expect(WhisperInstall.locate(searching: [notExecutable]).server == nil)
    }

    @Test func mainModelIsTheLargestPresentAndWakeModelTheSmallest() throws {
        let models = try folder(with: ["ggml-small.bin", "ggml-medium.bin", "ggml-base.en.bin"])
        #expect(WhisperInstall.preferredModel(in: models)?.lastPathComponent == "ggml-medium.bin")
        #expect(WhisperInstall.wakeWordModel(in: models)?.lastPathComponent == "ggml-base.en.bin")

        let turbo = try folder(with: ["ggml-large-v3-turbo.bin", "ggml-tiny.bin", "ggml-small.bin"])
        #expect(WhisperInstall.preferredModel(in: turbo)?.lastPathComponent == "ggml-large-v3-turbo.bin")
        #expect(WhisperInstall.wakeWordModel(in: turbo)?.lastPathComponent == "ggml-tiny.bin")

        let englishOnly = try folder(with: ["ggml-base.en.bin"])
        #expect(WhisperInstall.preferredModel(in: englishOnly) == nil)
    }


    // MARK: WhisperModelDownloader

    /// Test pins: the stub's payload, under the names the downloader is asked for.
    var stubPins: WhisperModels.Pins {
        WhisperModels.Pins(revision: "0123456789abcdef0123456789abcdef01234567",
                           files: ["ggml-small.bin": WhisperModels.sha256Hex(of: StubModel.payload)])
    }

    @Test func downloadWritesThePartFileThenRenamesAndReportsProgress() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubModel.self]
        StubModel.requested = []
        let models = try folder(with: [])
        let progress = ProgressLog()

        let file = try await WhisperModelDownloader(configuration: config, pins: stubPins)
            .download("small", into: models, progress: { progress.values.append($0) })

        #expect(file.path == models.appending(path: "ggml-small.bin").path)
        #expect(try Data(contentsOf: file) == StubModel.payload)
        #expect(try FileManager.default.contentsOfDirectory(atPath: models.path) == ["ggml-small.bin"])
        // J-026: from the pinned revision, never a moving branch.
        #expect(StubModel.requested.map(\.absoluteString)
                == ["https://huggingface.co/ggerganov/whisper.cpp/resolve/0123456789abcdef0123456789abcdef01234567/ggml-small.bin"])
        #expect(progress.values.last == 1.0)
    }

    /// J-026: a download that doesn't match its pinned sha256 never becomes a model, and leaves nothing behind.
    @Test func aDownloadWhoseChecksumDiffersIsRefusedAndRemoved() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubModel.self]
        let models = try folder(with: [])
        let wrong = WhisperModels.Pins(revision: stubPins.revision,
                                       files: ["ggml-small.bin": String(repeating: "0", count: 64)])

        await #expect(throws: WhisperError.checksumMismatch(file: "ggml-small.bin")) {
            try await WhisperModelDownloader(configuration: config, pins: wrong).download("small", into: models)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: models.path).isEmpty)
    }

    @Test func aModelThatIsNotPinnedIsNeverDownloaded() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubModel.self]
        StubModel.requested = []
        let models = try folder(with: [])

        await #expect(throws: WhisperError.notPinned(file: "ggml-tiny.bin")) {
            try await WhisperModelDownloader(configuration: config, pins: stubPins).download("tiny", into: models)
        }
        #expect(StubModel.requested.isEmpty)
    }

    /// The app's pins and the installer's manifest are one list: a change to one without the other fails here.
    @Test func theAppsPinsMatchTheInstallersManifest() throws {
        let manifest = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../install/whisper-models.txt")
        let lines = try String(contentsOf: manifest, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }.map { $0.split(separator: " ").map(String.init) }
        let revision = try #require(lines.first { $0.first == "revision" })[1]
        let files = Dictionary(uniqueKeysWithValues: lines.filter { $0.first != "revision" }.map { ($0[0], $0[1]) })

        #expect(WhisperModels.pinned.revision == revision)
        #expect(WhisperModels.pinned.files == files)
        #expect(Set(files.keys).isSuperset(of: ["ggml-small.bin", "ggml-medium.bin", "ggml-large-v3-turbo.bin"]))
    }

    @Test func ensureSmallKeepsAPresentModelWithoutTouchingTheNetwork() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubModel.self]
        StubModel.requested = []
        let models = try folder(with: ["ggml-small.bin"])

        let file = try await WhisperModelDownloader(configuration: config, pins: stubPins).ensureSmall(in: models)

        #expect(file.lastPathComponent == "ggml-small.bin")
        #expect(StubModel.requested.isEmpty)
    }


    // MARK: WhisperServerProcess

    @Test func restartBudgetAllowsThreeRelaunchesPerMinute() {
        var budget = RestartBudget()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let answers = [0, 10, 20, 30, 61].map { budget.allow(at: t0 + TimeInterval($0)) }
        // Three inside 60 s, a fourth refused, then allowed again once the first has aged out.
        #expect(answers == [true, true, true, false, true])
    }

    /// A fake server that appends the `--port` it was given to `ports.txt`, then exits after 0.5 s.
    private func flakyServer() throws -> (binary: URL, ports: URL) {
        let ports = try tempDir("ports").appending(path: "ports.txt")
        let binary = try fakeExecutable("whisper-server", """
        printf '%s\\n' "$4" >> '\(ports.path)'
        exec /bin/sleep 0.5
        """)
        return (binary, ports)
    }

    private func lines(_ file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// A socket listening on 127.0.0.1:`port`, as another program holding the port would.
    private func occupy(_ port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0 && listen(fd, 1) == 0)
        return fd
    }

    /// A previous run's server, left behind by a crash: a long-running fake, started by the test.
    private func orphan() throws -> (process: Process, binary: URL) {
        let binary = try fakeExecutable("whisper-server", "exec /bin/sleep 600")
        let process = Process()
        process.executableURL = binary
        try process.run()
        return (process, binary)
    }

    /// Bounded: `waitUntilExit()` here once missed the exit and hung the suite.
    private func reap(_ process: Process) {
        process.terminateAndWait()
    }

    private func gone(_ process: Process) async throws -> Bool {
        for _ in 0..<50 where process.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
        return !process.isRunning
    }

    @Test func startTerminatesTheServerAPreviousRunLeftBehindAndReusesItsPort() async throws {
        let old = try orphan()
        defer { reap(old.process) }
        let pid = old.process.processIdentifier
        let started = try #require(WhisperServerProcess.startTime(of: pid))
        let recordedPort = WhisperServerProcess.freePort(from: 17_455)
        let pidFile = try tempDir("pid").appending(path: "jarvis-whisper-main.pid")
        try "\(pid) \(started) \(recordedPort)".write(to: pidFile, atomically: true, encoding: .utf8)
        let server = WhisperServerProcess(binary: old.binary, model: URL(filePath: "/m.bin"), port: 17_701,
                                          pidFile: pidFile)
        defer { server.stop() }

        try? await server.start(timeout: 0.3)          // the fake never answers HTTP

        #expect(try await gone(old.process))
        #expect(server.port == recordedPort)
        let recorded = try String(contentsOf: pidFile, encoding: .utf8).split(separator: " ")
        #expect(recorded.first.map(String.init) == server.pid.map(String.init))
        #expect(recorded.last.map(String.init) == String(recordedPort))

        server.stop()
        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
    }

    @Test func startLeavesAProcessAloneWhenOnlyItsPidMatchesThePidFile() async throws {
        let unrelated = try orphan()
        defer { reap(unrelated.process) }
        let pidFile = try tempDir("pid").appending(path: "jarvis-whisper-wake.pid")
        // Same pid, different start time: the pid was recycled by another process.
        try "\(unrelated.process.processIdentifier) 1 17455".write(to: pidFile, atomically: true, encoding: .utf8)
        let server = WhisperServerProcess(binary: unrelated.binary, model: URL(filePath: "/m.bin"),
                                          port: WhisperServerProcess.freePort(from: 17_711), pidFile: pidFile)
        defer { server.stop() }

        try? await server.start(timeout: 0.3)

        #expect(unrelated.process.isRunning)
        #expect(server.port != 17_455)
    }

    @Test func aServerThatKeepsExitingStopsRelaunchingAndSurfacesTheError() async throws {
        let launches = try tempDir("launches").appending(path: "launches.txt")
        let dying = try fakeExecutable("whisper-server", "echo x >> '\(launches.path)'\nexit 1")
        let server = WhisperServerProcess(binary: dying, model: URL(filePath: "/m.bin"),
                                          port: WhisperServerProcess.freePort(from: 17_601))
        defer { server.stop() }

        await #expect(throws: WhisperError.serverKeepsExiting) { try await server.start(timeout: 10) }

        #expect(lines(launches).count == 4)             // the first launch plus 3 relaunches
        #expect(server.pid == nil)
        await #expect(throws: WhisperError.serverKeepsExiting) {
            try await WhisperTranscriber(backend: .server(server)).transcribe(self.oneSecond)
        }
    }

    // Gate repair: stop() runs at quit and before a relaunch; it must return even when the server
    // ignores SIGTERM, and must not hang on an exit it failed to notice.
    @Test func stopReturnsPromptlyEvenWhenTheServerIgnoresSIGTERM() async throws {
        let stubborn = try fakeExecutable("whisper-server", "trap '' TERM\nexec /bin/sleep 600")
        let server = WhisperServerProcess(binary: stubborn, model: URL(filePath: "/m.bin"),
                                          port: WhisperServerProcess.freePort(from: 17_721))
        try? await server.start(timeout: 0.3)          // the fake never answers HTTP; by now it has set its trap
        let pid = try #require(server.pid)
        let started = WhisperServerProcess.startTime(of: pid)
        defer { if WhisperServerProcess.startTime(of: pid) == started { kill(pid, SIGKILL) } }

        let stopping = Thread { server.stop() }     // a thread of its own: on red it never returns
        stopping.start()
        for _ in 0..<100 where !stopping.isFinished { try await Task.sleep(nanoseconds: 100_000_000) }

        #expect(stopping.isFinished)
        #expect(WhisperServerProcess.startTime(of: pid) == nil)
    }

    @Test func readinessWaitsForA200FromHealth() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHealth.self]
        let clock = VirtualScheduler()
        let server = WhisperServerProcess(binary: URL(filePath: "/bin/false"), model: URL(filePath: "/m.bin"),
                                          port: 17_171, session: URLSession(configuration: config), scheduler: clock)

        StubHealth.status = 503                         // whisper-server while the model is loading
        let waiting = Task { try await server.waitUntilReady(timeout: 0.5) }
        for _ in 0..<3 {                                // polls at 0, 0.2 and 0.4 s of virtual time, then gives up
            #expect(await clock.waitForPending())
            clock.advance(by: 0.2)
        }
        await #expect(throws: WhisperError.serverNotReady) { try await waiting.value }

        StubHealth.status = 200
        try await server.waitUntilReady(timeout: 2)     // the first poll answers
        #expect(StubHealth.lastURL?.absoluteString == "http://127.0.0.1:17171/health")
    }

    @Test func relaunchMovesToTheNextFreePortWhenItsPortWasTakenMeanwhile() async throws {
        let fake = try flakyServer()
        let server = WhisperServerProcess(binary: fake.binary, model: URL(filePath: "/m.bin"),
                                          port: WhisperServerProcess.freePort(from: 17_501))
        defer { server.stop() }
        try? await server.start(timeout: 0.2)          // the fake never answers HTTP
        let first = server.port
        let holder = try occupy(first)
        defer { close(holder) }

        for _ in 0..<50 where lines(fake.ports).count < 2 { try await Task.sleep(nanoseconds: 100_000_000) }

        let ports = lines(fake.ports)
        try #require(ports.count >= 2)
        #expect(ports[0] == String(first))
        #expect(ports[1] != String(first))
        #expect(server.port != first)
    }

    /// Wherever whisper.cpp is installed, and the best model in the repo's `models/` (main, else wake-word).
    static let install = WhisperInstall.locate()
    static let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let smokeModel = WhisperInstall.preferredModel(in: repoRoot.appending(path: "models"))
        ?? WhisperInstall.wakeWordModel(in: repoRoot.appending(path: "models"))
    static let evidence = repoRoot.appending(path: ".agentic/jarvis-ambient-memory/evidence/airpods3.wav")
    static var smokeInputsAvailable: Bool {
        smokeModel != nil && FileManager.default.fileExists(atPath: evidence.path)
    }

    private func evidenceChunk() throws -> AudioChunk {
        let file = try AVAudioFile(forReading: Self.evidence)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        return AudioChunk(samples: samples, sampleRate: file.processingFormat.sampleRate, start: Date(), source: .mic)
    }

    @Test(.enabled(if: install.server != nil && smokeInputsAvailable,
                   "needs whisper-server, a model in models/ and the evidence WAV"))
    func realServerTranscribesTakesTheNextPortAndRelaunchesAfterACrash() async throws {
        let binary = try #require(Self.install.server), model = try #require(Self.smokeModel)
        let main = WhisperServerProcess(binary: binary, model: model, port: 17_271)
        let wake = WhisperServerProcess(binary: binary, model: model, port: 17_271)
        defer { main.stop(); wake.stop() }

        try await main.start()
        try await wake.start()
        #expect(main.port == 17_271)
        #expect(wake.port == 17_272)        // 17 271 was taken by `main`

        let text = try await WhisperTranscriber(backend: .server(main)).transcribe(evidenceChunk())
        #expect(text.localizedCaseInsensitiveContains("test recording"))

        let crashed = try #require(main.pid)
        kill(crashed, SIGKILL)
        var relaunched = false
        for _ in 0..<100 where !relaunched {
            try await Task.sleep(nanoseconds: 100_000_000)
            relaunched = main.pid != nil && main.pid != crashed
        }
        #expect(relaunched)
        try await main.waitUntilReady()
        #expect(main.failure == nil)

        main.stop()
        #expect(kill(try #require(wake.pid), 0) == 0)   // stopping one leaves the other running
        #expect(main.pid == nil)
    }


    @Test func wavWriterResamples48kTo16k() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "wavtest-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let tone = (0..<48_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.5 }

        try WAVWriter.write(AudioChunk(samples: tone, sampleRate: 48_000, start: Date(), source: .mic), to: url)

        let frames = (try Data(contentsOf: url).count - 44) / 2
        #expect(abs(frames - 16_000) < 200)     // one second at 16 kHz, give or take converter latency
    }

    @Test(.enabled(if: install.cli != nil && smokeInputsAvailable,
                   "needs whisper-cli, a model in models/ and the evidence WAV"))
    func realCLITranscribesTheEvidenceFile() async throws {
        let transcriber = WhisperTranscriber(backend: .cli(binary: try #require(Self.install.cli),
                                                           model: try #require(Self.smokeModel)))
        let text = try await transcriber.transcribe(evidenceChunk())
        #expect(text.localizedCaseInsensitiveContains("test recording"))
    }

}

/// Answers every request with `reply` and keeps the last request and its body for inspection.
final class StubInference: URLProtocol {
    nonisolated(unsafe) static var reply = ""
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody = Data()
    /// The `jarvis-*.wav` files in the temp directory while the last request was in flight.
    nonisolated(unsafe) static var tempWAVsDuringRequest: Set<String> = []

    static func tempWAVs() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("jarvis-") && $0.hasSuffix(".wav") })
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        Self.tempWAVsDuringRequest = Self.tempWAVs()
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.drain) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

final class ProgressLog: @unchecked Sendable { var values: [Double] = [] }

/// Serves `payload` for any URL, with a Content-Length, and records what was asked for.
final class StubModel: URLProtocol {
    static let payload = Data((0..<200_000).map { UInt8($0 % 251) })
    nonisolated(unsafe) static var requested: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requested.append(request.url!)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Length": "\(Self.payload.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Answers every request with an empty body and `status`, and keeps the last URL asked for.
final class StubHealth: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var lastURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastURL = request.url
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
