import Foundation
import NaturalLanguage

/// Apple's built-in NaturalLanguage embeddings: the baseline `Embedder` on every Mac.
///
/// Empty or whitespace-only text is a zero vector. Non-empty text the sentence model cannot embed
/// falls back to the mean of its known words' vectors, which is also zero when no word is known.
/// A zero vector has no direction, so cosine callers must guard a zero norm.
public struct NLEmbedder: Embedder {
    public struct Unavailable: Error {}

    public let displayName = "NaturalLanguage"
    /// Loaded once, not per `embed` call, so bulk indexing does not reload the model.
    private let sentence: NLEmbedding?
    private let words: NLEmbedding?

    public init() {
        self.init(sentence: NLEmbedding.sentenceEmbedding(for: .english),
                  words: NLEmbedding.wordEmbedding(for: .english))
    }

    init(sentence: NLEmbedding?, words: NLEmbedding?) {
        self.sentence = sentence
        self.words = words
    }

    public func embed(_ text: String) throws -> [Float] {
        if text.allSatisfy(\.isWhitespace), let dimension = (sentence ?? words)?.dimension {
            return Array(repeating: 0, count: dimension)
        }
        if let vector = sentence?.vector(for: text) { return vector.map(Float.init) }
        guard let words else { throw Unavailable() }
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
