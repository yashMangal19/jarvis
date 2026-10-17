import Accelerate

/// Decides whether a chunk is too quiet to be worth transcribing.
public struct SilenceGate {
    /// Fixed by the spec ("a fixed threshold"): a constant, never a setting.
    public static let thresholdDbFS: Float = -50

    public init() {}

    /// True when the chunk's RMS level is below `thresholdDbFS`. A chunk with no samples is silent.
    public func isSilent(_ chunk: AudioChunk) -> Bool {
        guard !chunk.samples.isEmpty else { return true }
        let rms = vDSP.rootMeanSquare(chunk.samples)
        return 20 * log10(rms) < Self.thresholdDbFS
    }
}
