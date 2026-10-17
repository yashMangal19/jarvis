#if canImport(CoreAI)
import CoreAI
import Foundation

/// Core AI (macOS 27) embeddings from a user-supplied model file in `~/Jarvis/models`.
///
/// Core AI is a generic tensor runtime with no text or tokenizer API, so Jarvis expects a
/// byte-level encoder: function `main`, input `input_ids` (int32, `[1, n]`, the text's UTF-8
/// bytes), output `embedding` (float32, last dimension fixed). Ceiling: a model with a
/// WordPiece/BPE vocabulary needs a tokenizer beside it; that is the upgrade path, not this file.
@available(macOS 27, *)
public struct CoreAIEmbedder: Embedder {
    public struct UnexpectedOutput: Error {}

    /// The model file Jarvis expects in `JarvisPaths.models`.
    public static let modelFileName = "jarvis-embedding.aimodel"

    public let displayName = "Core AI"
    public let dimension: Int
    private let function: InferenceFunction

    /// `nil` when disabled, when the file is absent, when Core AI throws, or when the model's
    /// function does not match the contract above — any of these means "fall back".
    public static func load(from models: URL,
                            environment: [String: String] = ProcessInfo.processInfo.environment)
        -> CoreAIEmbedder? {
        // Developer override: forces the NaturalLanguage fallback without deleting the model.
        guard environment["JARVIS_DISABLE_COREAI"] != "1" else { return nil }
        let url = models.appending(path: modelFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let loaded = try? blocking { () async throws -> CoreAIEmbedder? in
            // Specialises for this Mac on first load (can be slow), cached by Core AI afterwards.
            let model = try await AIModel(contentsOf: url)
            guard let function = try model.loadFunction(named: "main"),
                  case .ndArray(let input)? = function.descriptor.inputDescriptor(of: "input_ids"),
                  input.scalarType == .int32,
                  case .ndArray(let output)? = function.descriptor.outputDescriptor(of: "embedding"),
                  output.scalarType == .float32,
                  let dimension = output.shape.last, dimension > 0
            else { return nil }
            return CoreAIEmbedder(dimension: dimension, function: function)
        }
        return loaded ?? nil
    }

    public func embed(_ text: String) throws -> [Float] {
        let ids = text.utf8.map(Int32.init)
        let function = function
        let vector = try Self.blocking { () async throws -> [Float] in
            var outputs = try await function.run(
                inputs: ["input_ids": NDArray(scalars: ids, shape: [1, ids.count])])
            guard let array = outputs.remove("embedding")?.ndArray,
                  let elements = array.view(as: Float.self).contiguousElements
            else { throw UnexpectedOutput() }
            return (0..<elements.count).map { elements[$0] }
        }
        guard vector.count == dimension else { throw UnexpectedOutput() }
        return vector
    }

    /// `Embedder` and engine selection are synchronous (D-4); Core AI is async. Ceiling: blocks
    /// the calling thread for the duration of one load or one inference.
    private static func blocking<T>(_ work: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try result!.get()
    }
}
#endif
