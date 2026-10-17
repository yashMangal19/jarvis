import Foundation

/// The last `seconds` of mic audio, in memory only. Pure: no clock, no I/O — nothing here ever
/// reaches the disk. Positions are stream time: seconds of audio appended since the buffer was made.
public struct RollingAudioBuffer {
    public let sampleRate: Double
    private let capacity: Int
    private var storage: [Float] = []
    private var appended = 0

    public init(seconds: Double, sampleRate: Double = 16_000) {
        self.sampleRate = sampleRate
        self.capacity = Int(seconds * sampleRate)
    }

    /// Stream time just after the newest sample.
    public var end: TimeInterval { Double(appended) / sampleRate }

    /// Appends `samples`, dropping the oldest audio beyond the capacity.
    public mutating func append(_ samples: [Float]) {
        storage += samples
        appended += samples.count
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
    }

    /// Every retained sample from stream time `offset` to `end`; an evicted `offset` starts at the oldest.
    public func samples(from offset: TimeInterval) -> [Float] {
        let skip = Int((offset * sampleRate).rounded()) - (appended - storage.count)
        return Array(storage.dropFirst(max(0, skip)))
    }
}
