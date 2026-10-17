import Foundation
import Testing
import JarvisCore

@Suite struct ChunkAssemblerTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func seventyFiveSecondsInOneSecondPiecesMakeTwoChunksAndAFifteenSecondFlush() {
        var assembler = ChunkAssembler(sampleRate: 16_000, chunkSeconds: 30, source: .mic)
        var chunks: [AudioChunk] = []
        for second in 0..<75 {
            let piece = [Float](repeating: Float(second), count: 16_000)
            chunks += assembler.append(piece, at: t0.addingTimeInterval(Double(second)))
        }
        let rest = assembler.flush()

        #expect(chunks.map(\.start) == [t0, t0.addingTimeInterval(30)])
        #expect(chunks.map(\.samples.count) == [480_000, 480_000])
        #expect(chunks[1].samples.first == 30)
        #expect(chunks.allSatisfy { $0.source == .mic && $0.sampleRate == 16_000 })
        #expect(rest?.start == t0.addingTimeInterval(60))
        #expect(rest?.duration == 15)
        #expect(rest?.samples.first == 60)
        #expect(assembler.flush() == nil)
    }
}
