import Testing
import NaturalLanguage
@testable import JarvisCore

@Suite struct NLEmbedderTests {
    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let na = a.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let nb = b.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return dot / (na * nb)
    }

    @Test func relatedSentencesAreCloserThanUnrelated() throws {
        let embedder = NLEmbedder()
        let anchor = try embedder.embed("we agreed to cap the holiday spend")
        let related = try embedder.embed("how much can we spend on the trip")
        let unrelated = try embedder.embed("the kernel panicked on boot")
        #expect(cosine(anchor, related) > cosine(anchor, unrelated))
    }

    @Test func emptyTextIsAZeroVectorOfTheModelDimension() throws {
        let vector = try NLEmbedder().embed("")
        #expect(vector.count == NLEmbedding.sentenceEmbedding(for: .english)?.dimension)
        #expect(vector.allSatisfy { $0 == 0 })
    }

    @Test func wordFallbackAveragesKnownWordsAndKeepsOrdering() throws {
        let words = try #require(NLEmbedding.wordEmbedding(for: .english))
        let anchor = NLEmbedder.averagedWordVector("holiday budget money", words)
        let related = NLEmbedder.averagedWordVector("vacation spending cash", words)
        let unrelated = NLEmbedder.averagedWordVector("kernel panic boot", words)
        #expect(anchor.count == words.dimension)
        #expect(cosine(anchor, related) > cosine(anchor, unrelated))
        let budget = try #require(words.vector(for: "budget")), money = try #require(words.vector(for: "money"))
        let mean = NLEmbedder.averagedWordVector("Budget, money!", words)
        #expect(abs(mean[0] - Float((budget[0] + money[0]) / 2)) < 1e-5)
        #expect(NLEmbedder.averagedWordVector("zzqxv", words).allSatisfy { $0 == 0 })
    }
}
