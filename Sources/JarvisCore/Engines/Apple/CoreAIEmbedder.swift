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
    /// The model's fixed sequence length, or `nil` when `input_ids` has a dynamic length.
    let maxInputLength: Int?
    /// One inference: UTF-8 byte ids in, the `embedding` output out.
    private let run: @Sendable ([Int32]) async throws -> [Float]

    init(dimension: Int, maxInputLength: Int? = nil,
         run: @escaping @Sendable ([Int32]) async throws -> [Float]) {
        self.dimension = dimension
        self.maxInputLength = maxInputLength
        self.run = run
    }

    /// `nil` when disabled, when the file is absent, when Core AI throws, or when the model's
    /// function does not match the contract above — any of these means "fall back".
    public static func load(from models: URL,
                            environment: [String: String] = ProcessInfo.processInfo.environment)
        async -> CoreAIEmbedder? {
        // Developer override: forces the NaturalLanguage fallback without deleting the model.
        guard environment["JARVIS_DISABLE_COREAI"] != "1" else { return nil }
        let url = models.appending(path: modelFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // First load specialises the model for this Mac and can be slow.
        guard let model = try? await AIModel(contentsOf: url),
              let function = try? model.loadFunction(named: "main"),
              case .ndArray(let input)? = function.descriptor.inputDescriptor(of: "input_ids"),
              input.scalarType == .int32, input.rank == 2,
              case .ndArray(let output)? = function.descriptor.outputDescriptor(of: "embedding"),
              output.scalarType == .float32,
              let dimension = output.shape.last, dimension > 0
        else { return nil }
        // A dynamic dimension reads as -1 (NDArrayDescriptor.resolvingDynamicDimensions docs).
        let sequence = input.shape[1]
        return CoreAIEmbedder(dimension: dimension, maxInputLength: sequence > 0 ? sequence : nil) { ids in
            var outputs = try await function.run(
                inputs: ["input_ids": NDArray(scalars: ids, shape: [1, ids.count])])
            guard let array = outputs.remove("embedding")?.ndArray,
                  let elements = array.view(as: Float.self).contiguousElements
            else { throw UnexpectedOutput() }
            return (0..<elements.count).map { elements[$0] }
        }
    }

    /// Empty text is the zero vector (as `NLEmbedder`); longer text than the model's fixed
    /// sequence length is truncated to it. Ceiling: a fixed-length model given shorter text
    /// still fails at inference — padding is model-specific and this contract defines none.
    public func embed(_ text: String) throws -> [Float] {
        guard !text.isEmpty else { return Array(repeating: 0, count: dimension) }
        let ids = Array(text.utf8.map(Int32.init).prefix(maxInputLength ?? .max))
        let run = run
        let vector = try Self.blocking { try await run(ids) }
        guard vector.count == dimension else { throw UnexpectedOutput() }
        return vector
    }

    /// `Embedder` is synchronous (D-4); Core AI is async. The async work runs with a task-executor
    /// preference for `InferenceExecutor` — a private GCD serial queue, not Swift's shared
    /// cooperative pool — so a caller blocked here never waits on a pool thread to run its own
    /// work. Safe callers: any thread (main, GCD, `Thread`), and async tasks, which no longer
    /// deadlock by exhausting the pool. Ceiling: an async caller still occupies one pool thread
    /// for the duration of one inference, and inferences are serialised; if Core AI internally
    /// hops to the global executor while every pool thread is blocked here, that hop waits — call
    /// `embed` from a non-pool thread when embedding at high concurrency.
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task(executorPreference: InferenceExecutor.shared) {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}

/// Written once by the task, read once after the semaphore — the semaphore orders the two.
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Runs Core AI inference jobs on a dedicated serial queue instead of the cooperative pool.
@available(macOS 27, *)
private final class InferenceExecutor: TaskExecutor {
    static let shared = InferenceExecutor()
    private let queue = DispatchQueue(label: "jarvis.coreai.inference")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
#endif
