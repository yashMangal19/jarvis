import Foundation
import Testing
import JarvisCore

/// Answers every request in-process; no socket is opened.
final class OllamaStub: URLProtocol {
    nonisolated(unsafe) static var handler: (URLRequest, Data) throws -> (Int, Data) = { _, _ in (500, Data()) }
    nonisolated(unsafe) static var seen: [(URLRequest, Data)] = []

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable, case let n = stream.read(&buffer, maxLength: buffer.count), n > 0 {
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.seen.append((request, body))
        do {
            let (status, data) = try Self.handler(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

@Suite(.serialized) struct OllamaNoteWriterTests {
    let base = URL(string: "http://127.0.0.1:11434")!

    init() { OllamaStub.seen = [] }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func postsPromptAndTranscriptAndReturnsResponse() async throws {
        OllamaStub.handler = { _, _ in (200, Data(#"{"model":"llama3.2","response":"- Agreed a cap.","done":true}"#.utf8)) }
        let writer = OllamaNoteWriter(baseURL: base, model: "llama3.2", session: OllamaStub.session())

        let note = try await writer.note(from: "we agreed to cap it", prompt: "Summarise.")

        #expect(note == "- Agreed a cap.")
        let (request, body) = try #require(OllamaStub.seen.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/generate")
        let sent = try json(body)
        #expect(sent["model"] as? String == "llama3.2")
        #expect(sent["prompt"] as? String == "Summarise.\n\nwe agreed to cap it")
        #expect(sent["stream"] as? Bool == false)
        #expect(writer.displayName == "Ollama (llama3.2)")
    }

    @Test func unsetModelUsesTheFirstInstalledTag() async throws {
        OllamaStub.handler = { request, _ in
            request.url?.path == "/api/tags"
                ? (200, Data(#"{"models":[{"name":"qwen2.5:3b"},{"name":"llama3.2:latest"}]}"#.utf8))
                : (200, Data(#"{"response":"ok"}"#.utf8))
        }
        let writer = OllamaNoteWriter(baseURL: base, session: OllamaStub.session())

        _ = try await writer.note(from: "t", prompt: "p")

        try #require(OllamaStub.seen.map { $0.0.url?.path } == ["/api/tags", "/api/generate"])
        #expect(try json(OllamaStub.seen[1].1)["model"] as? String == "qwen2.5:3b")
    }

    @Test func serverErrorIsThrownNotWrittenAsANote() async throws {
        OllamaStub.handler = { _, _ in (404, Data(#"{"error":"model 'x' not found"}"#.utf8)) }
        let writer = OllamaNoteWriter(baseURL: base, model: "x", session: OllamaStub.session())

        let error = await #expect(throws: OllamaNoteWriter.Failure.self) {
            try await writer.note(from: "t", prompt: "p")
        }
        #expect(error?.status == 404)
        #expect(error?.body.contains("not found") == true)
    }

    @Test func availableOnlyWhenTagsAnswerWithinTwoSeconds() async throws {
        OllamaStub.handler = { _, _ in (200, Data(#"{"models":[]}"#.utf8)) }
        #expect(await OllamaInstall.isAvailable(session: OllamaStub.session()))
        #expect(OllamaStub.seen.last?.0.url?.path == "/api/tags")
        #expect(OllamaStub.seen.last?.0.timeoutInterval == 2)

        OllamaStub.handler = { _, _ in throw URLError(.cannotConnectToHost) }
        #expect(await OllamaInstall.isAvailable(session: OllamaStub.session()) == false)
    }

    @Test func installedWhenTheBinaryIsInASearchedDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(OllamaInstall.isInstalled(searching: [dir.path]) == false)

        let binary = dir.appendingPathComponent("ollama")
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        #expect(OllamaInstall.isInstalled(searching: [dir.path]))
    }

    /// Talks to a real server; opt in with JARVIS_OLLAMA_SMOKE=1 (tests use no network by default).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JARVIS_OLLAMA_SMOKE"] == "1"))
    func smokeAgainstALocalServer() async throws {
        try #require(await OllamaInstall.isAvailable())
        let note = try await OllamaNoteWriter().note(from: "We agreed to cap the holiday spend at 2000.", prompt: "Summarise in one line.")
        #expect(!note.isEmpty)
    }
}
