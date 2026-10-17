import Foundation
import NaturalLanguage

/// Apple's contextual (BERT-style) NaturalLanguage embeddings, macOS 14+: the tier between Core AI and
/// `NLEmbedder`. The assets are system-managed — no model file of ours. One vector per text is the
/// mean of its subword token vectors.
///
/// Ceiling: the model reads at most `maximumSequenceLength` tokens (256 for English on macOS 27) and
/// silently ignores the rest, so a long note is embedded by its opening. Upgrade path: embed in windows
/// and average them.
@available(macOS 14, *)
public struct NLContextualEmbedder: Embedder {
    private let model: NLContextualEmbedding

    var dimension: Int { model.dimension }

    /// `nil` when there is no English model, its assets cannot be fetched, or it fails to load —
    /// any of these means "fall back". May download Apple's assets on first use.
    public static func load() async -> NLContextualEmbedder? {
        guard let model = NLContextualEmbedding(language: .english) else { return nil }
        if !model.hasAvailableAssets {
            guard (try? await model.requestAssets()) == .available else { return nil }
        }
        guard (try? model.load()) != nil else { return nil }
        return NLContextualEmbedder(model: model)
    }

    /// Text with no tokens (empty, whitespace) is the zero vector, as `NLEmbedder`.
    public func embed(_ text: String) throws -> [Float] {
        let result = try model.embeddingResult(for: text, language: .english)
        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for i in sum.indices { sum[i] += vector[i] }
            count += 1
            return true
        }
        return sum.map { count == 0 ? 0 : Float($0 / Double(count)) }
    }
}
