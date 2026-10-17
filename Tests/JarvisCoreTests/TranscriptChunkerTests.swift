import Testing
import JarvisCore

@Suite struct TranscriptChunkerTests {
    // Ten 6-character lines; 27 characters fit exactly four lines and their three newlines.
    private let tenLines = (0..<10).map { "line \($0)" }.joined(separator: "\n")

    @Test func splitsOnLineBoundariesAndRoundTrips() {
        let chunks = TranscriptChunker.chunks(tenLines, maxCharacters: 27)

        #expect(chunks.count == 3)
        #expect(chunks.joined(separator: "\n") == tenLines)
    }
}
