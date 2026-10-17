import Foundation

/// Cuts a stream of samples into fixed-length `AudioChunk`s. Pure: no clock, no I/O.
public struct ChunkAssembler {
    private let sampleRate: Double
    private let chunkLength: Int
    private let source: AudioSource
    private var buffer: [Float] = []
    private var bufferStart: Date?

    public init(sampleRate: Double = 16_000, chunkSeconds: Double = 30, source: AudioSource) {
        self.sampleRate = sampleRate
        self.chunkLength = Int(sampleRate * chunkSeconds)
        self.source = source
    }

    /// Adds `samples`, whose first sample was heard at `time`, and returns every chunk now full.
    /// Each chunk starts at the time of its first sample; samples are assumed contiguous until `flush`.
    public mutating func append(_ samples: [Float], at time: Date) -> [AudioChunk] {
        if buffer.isEmpty { bufferStart = time }
        buffer += samples
        var chunks: [AudioChunk] = []
        while buffer.count >= chunkLength, let start = bufferStart {
            chunks.append(AudioChunk(samples: Array(buffer.prefix(chunkLength)), sampleRate: sampleRate,
                                     start: start, source: source))
            buffer.removeFirst(chunkLength)
            bufferStart = start.addingTimeInterval(Double(chunkLength) / sampleRate)
        }
        return chunks
    }

    /// The partial chunk, if any; the assembler is empty afterwards.
    public mutating func flush() -> AudioChunk? {
        defer { buffer = []; bufferStart = nil }
        guard !buffer.isEmpty, let start = bufferStart else { return nil }
        return AudioChunk(samples: buffer, sampleRate: sampleRate, start: start, source: source)
    }
}
