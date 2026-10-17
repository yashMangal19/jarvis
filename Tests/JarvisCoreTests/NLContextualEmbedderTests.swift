import Foundation
import NaturalLanguage
import Testing
@testable import JarvisCore

/// Runs against Apple's system-managed English assets; skipped on a Mac that does not have them yet.
@Suite(.enabled(if: NLContextualEmbedding(language: .english)?.hasAvailableAssets == true,
                "Apple's English contextual assets are not on this Mac"))
struct NLContextualEmbedderTests {
    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let na = a.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let nb = b.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return dot / (na * nb)
    }

    @Test func relatedSentencesAreCloserThanUnrelated() throws {
        let embedder = try #require(NLContextualEmbedder.load())
        #expect(embedder.displayName == "Apple contextual")
        let anchor = try embedder.embed("we agreed to cap the holiday spend")
        let related = try embedder.embed("how much can we spend on the trip")
        let unrelated = try embedder.embed("the kernel panicked on boot")
        #expect(anchor.count == embedder.dimension)
        #expect(cosine(anchor, related) > cosine(anchor, unrelated))
    }
}

extension NLContextualEmbedderTests {
    @Test func textWithNoTokensIsAZeroVectorOfTheModelDimension() throws {
        let embedder = try #require(NLContextualEmbedder.load())
        for text in ["", "  \n\t "] {
            let vector = try embedder.embed(text)
            #expect(vector.count == embedder.dimension)
            #expect(vector.allSatisfy { $0 == 0 })
        }
    }
}
