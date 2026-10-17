import AVFAudio
import Foundation
import Testing
@testable import JarvisCore

@Suite(.serialized) struct WhisperTranscriberTests {
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
        let dir = FileManager.default.temporaryDirectory.appending(path: "fakecli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appending(path: "whisper-cli")
        let argsFile = dir.appending(path: "args.txt")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argsFile.path)'
        printf '%s' '\(output)'
        exit \(status)
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
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

    // MARK: WhisperInstall

    private func folder(with files: [String], executable: Bool = false) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

    @Test func downloadWritesThePartFileThenRenamesAndReportsProgress() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubModel.self]
        StubModel.requested = []
        let models = try folder(with: [])
        let progress = ProgressLog()

        let file = try await WhisperModelDownloader(configuration: config)
            .download("small", into: models, progress: { progress.values.append($0) })

        #expect(file.path == models.appending(path: "ggml-small.bin").path)
        #expect(try Data(contentsOf: file) == StubModel.payload)
        #expect(try FileManager.default.contentsOfDirectory(atPath: models.path) == ["ggml-small.bin"])
        #expect(StubModel.requested.map(\.absoluteString)
                == ["https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"])
        #expect(progress.values.last == 1.0)
    }

    @Test func ensureSmallKeepsAPresentModelWithoutTouchingTheNetwork() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubModel.self]
        StubModel.requested = []
        let models = try folder(with: ["ggml-small.bin"])

        let file = try await WhisperModelDownloader(configuration: config).ensureSmall(in: models)

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

    static let serverBinary = URL(filePath: "/opt/homebrew/bin/whisper-server")
    static let englishModel = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "models/ggml-base.en.bin")
    static let evidence = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: ".agentic/jarvis-ambient-memory/evidence/airpods3.wav")
    static var serverSmokeAvailable: Bool {
        [serverBinary, englishModel, evidence].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func evidenceChunk() throws -> AudioChunk {
        let file = try AVAudioFile(forReading: Self.evidence)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        return AudioChunk(samples: samples, sampleRate: file.processingFormat.sampleRate, start: Date(), source: .mic)
    }

    @Test(.enabled(if: serverSmokeAvailable, "needs whisper-server, models/ggml-base.en.bin and the evidence WAV"))
    func realServerTranscribesTakesTheNextPortAndRelaunchesAfterACrash() async throws {
        let main = WhisperServerProcess(binary: Self.serverBinary, model: Self.englishModel, port: 17_271)
        let wake = WhisperServerProcess(binary: Self.serverBinary, model: Self.englishModel, port: 17_271)
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

    static let cliBinary = URL(filePath: "/opt/homebrew/bin/whisper-cli")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: cliBinary.path) && serverSmokeAvailable,
                   "needs whisper-cli, models/ggml-base.en.bin and the evidence WAV"))
    func realCLITranscribesTheEvidenceFile() async throws {
        let transcriber = WhisperTranscriber(backend: .cli(binary: Self.cliBinary, model: Self.englishModel))
        let text = try await transcriber.transcribe(evidenceChunk())
        #expect(text.localizedCaseInsensitiveContains("test recording"))
    }

}

/// Answers every request with `reply` and keeps the last request and its body for inspection.
final class StubInference: URLProtocol {
    nonisolated(unsafe) static var reply = ""
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
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
