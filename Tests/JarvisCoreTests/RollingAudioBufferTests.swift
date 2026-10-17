import Testing
import JarvisCore

@Suite struct RollingAudioBufferTests {
    /// One second of 16 kHz samples, every sample equal to `value`.
    private func second(_ value: Float) -> [Float] { [Float](repeating: value, count: 16_000) }

    @Test func aThreeSecondBufferHoldsOnlyTheLastThreeSecondsAfterFive() {
        var buffer = RollingAudioBuffer(seconds: 3)
        for s in 0..<5 { buffer.append(second(Float(s))) }

        let all = buffer.samples(from: 0)
        #expect(all.count == 48_000)
        #expect(all.first == 2 && all.last == 4)
        #expect(buffer.end == 5)
    }

    @Test func samplesFromAnOffsetStartThereAndAnEvictedOffsetStartsAtTheOldest() {
        var buffer = RollingAudioBuffer(seconds: 3)
        for s in 0..<5 { buffer.append(second(Float(s))) }

        #expect(buffer.samples(from: 3.5).count == 24_000)
        #expect(buffer.samples(from: 3.5).first == 3)
        #expect(buffer.samples(from: 1) == buffer.samples(from: 0))
        #expect(buffer.samples(from: 5).isEmpty)
    }
}
