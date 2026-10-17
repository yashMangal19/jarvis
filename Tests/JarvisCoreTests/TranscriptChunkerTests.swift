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

    @Test func aLineOverTheBudgetBecomesItsOwnChunk() {
        let chunks = TranscriptChunker.chunks("ab\nabcdefgh\ncd", maxCharacters: 4)

        #expect(chunks == ["ab", "abcdefgh", "cd"])
    }

    @Test func aLeadingBlankLineRoundTrips() {
        let chunks = TranscriptChunker.chunks("\nabc", maxCharacters: 10)

        #expect(chunks == ["\nabc"])
    }

    @Test func aBlankLineAfterAFullChunkRoundTrips() {
        let chunks = TranscriptChunker.chunks("aaaa\n\nbbbb", maxCharacters: 4)

        #expect(chunks.joined(separator: "\n") == "aaaa\n\nbbbb")
        #expect(!chunks.contains { $0.allSatisfy(\.isWhitespace) })
    }

    @Test func trailingBlankLinesMakeNoBlankChunk() {
        let chunks = TranscriptChunker.chunks("aaaa\n\n", maxCharacters: 4)

        #expect(chunks == ["aaaa\n\n"])
    }

    // Twelve 8-character lines with a 10-character budget: one line per chunk.
    private let twelveLines = Array(repeating: "aaaaaaaa", count: 12).joined(separator: "\n")

    @Test func textThatFitsIsWrittenInOneCall() async throws {
        var calls: [String] = []
        let note = try await TranscriptChunker.reduce("short", maxCharacters: 10) { calls.append($0); return "note" }

        #expect(note == "note")
        #expect(calls == ["short"])
    }

    @Test func partialNotesOverTheBudgetAreChunkedAndMergedAgain() async throws {
        var calls: [String] = []
        let note = try await TranscriptChunker.reduce(twelveLines, maxCharacters: 10) { calls.append($0); return "x" }

        // 12 chunk calls; 12 partials (34 chars) re-chunk into 3; their 3 partials fit one merge.
        #expect(note == "x")
        #expect(calls.count == 12 + 3 + 1)
        #expect(calls.last == "x\n\nx\n\nx")
    }

    @Test func partialNotesThatNeverFitThrowAfterTheRoundCap() async {
        var calls = 0
        await #expect(throws: TranscriptChunkerError.partialNotesTooLong(rounds: 3)) {
            try await TranscriptChunker.reduce(twelveLines, maxCharacters: 10, maxRounds: 3) { calls += 1; return $0 }
        }
        #expect(calls == 12 * 3)
    }
}
