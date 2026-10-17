import Foundation
import NaturalLanguage

/// Apple's built-in NaturalLanguage embeddings: the baseline `Embedder` on every Mac.
public struct NLEmbedder: Embedder {
    public struct Unavailable: Error {}

    public let displayName = "NaturalLanguage"

    public init() {}

    public func embed(_ text: String) throws -> [Float] {
        if let sentence = NLEmbedding.sentenceEmbedding(for: .english) {
            return sentence.vector(for: text).map { $0.map(Float.init) }
                ?? Array(repeating: 0, count: sentence.dimension)
        }
        guard let words = NLEmbedding.wordEmbedding(for: .english) else { throw Unavailable() }
        return Self.averagedWordVector(text, words)
    }

    /// Fallback when the sentence model is missing: the mean of the known words' vectors.
    static func averagedWordVector(_ text: String, _ words: NLEmbedding) -> [Float] {
        var sum = [Float](repeating: 0, count: words.dimension)
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, _, _, _ in
            guard let vector = word.flatMap({ words.vector(for: $0.lowercased()) }) else { return }
            for i in sum.indices { sum[i] += Float(vector[i]) }
            count += 1
        }
        return count == 0 ? sum : sum.map { $0 / Float(count) }
    }
}
