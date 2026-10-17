import Foundation

/// One window of captured or imported audio.
public struct AudioChunk {
    public let samples: [Float]
    public let sampleRate: Double
    public let start: Date
    public let source: AudioSource

    public init(samples: [Float], sampleRate: Double, start: Date, source: AudioSource) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.start = start
        self.source = source
    }

    /// Seconds of audio in this chunk.
    public var duration: TimeInterval {
        Double(samples.count) / sampleRate
    }
}

/// Where a chunk came from. The source decides the speaker label (see `label`).
public enum AudioSource {
    case mic
    case systemAudio
    case roomMic
    case imported

    /// Who the audio belongs to. The source decides the label (D-7):
    /// the active mic is the user; system audio and the room mic are other people;
    /// an imported recording comes from the user's own recorder, so it follows the mic rule.
    public var label: SpeakerLabel {
        switch self {
        case .mic, .imported: return .me
        case .systemAudio, .roomMic: return .others
        }
    }
}

/// Who is speaking, as far as Jarvis can tell from the source.
public enum SpeakerLabel: String, Codable {
    case me = "Me"
    case others = "Others"
}
