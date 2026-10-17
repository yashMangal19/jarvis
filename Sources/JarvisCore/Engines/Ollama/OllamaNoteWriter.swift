import Foundation

/// Writes notes with a local Ollama server — the optional engine for Macs without Claude.
public struct OllamaNoteWriter: NoteWriter {
    public struct Failure: Error, Equatable {
        public let status: Int
        public let body: String
    }

    /// `/api/tags` answered 200 with an empty model list: Ollama runs but nothing was pulled.
    public struct NoModelInstalled: Error {}

    private let baseURL: URL
    private let model: String?
    private let session: URLSession

    public init(baseURL: URL = OllamaInstall.defaultURL, model: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
    }

    public var displayName: String { model.map { "Ollama (\($0))" } ?? "Ollama" }

    public func note(from transcript: String, prompt: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Generate(model: try await resolvedModel(), prompt: "\(prompt)\n\n\(transcript)", stream: false))
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(status: status, body: String(decoding: data, as: UTF8.self)) }
        return try JSONDecoder().decode(Generated.self, from: data).response
    }

    /// The configured model, else the first one `ollama pull` installed.
    private func resolvedModel() async throws -> String {
        if let model { return model }
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent("api/tags"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(status: status, body: String(decoding: data, as: UTF8.self)) }
        guard let first = try JSONDecoder().decode(Tags.self, from: data).models.first?.name else {
            throw NoModelInstalled()
        }
        return first
    }

    private struct Tags: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
    private struct Generate: Encodable { let model: String, prompt: String, stream: Bool }
    private struct Generated: Decodable { let response: String }
}
