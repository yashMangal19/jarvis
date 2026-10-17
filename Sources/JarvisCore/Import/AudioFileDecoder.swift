import AVFAudio
import Foundation

public enum ImportError: Error {
    case unreadable(URL)
    /// The recording's lines are stored but the file could not be deleted.
    case notDeleted(URL, any Error)
}

/// Decodes an audio file into 30-second, 16 kHz mono chunks labelled as imported.
public enum AudioFileDecoder {
    public static let supportedExtensions: Set<String> = ["m4a", "mp3", "wav", "caf", "aiff", "aac", "mp4"]
    static let sampleRate = 16_000.0

    /// Chunk `n` starts at `recordedAt + n × 30 s`.
    /// Ceiling: every chunk of the file is held at once (~230 MB per hour of audio). If long
    /// recordings matter, hand chunks to a callback as they fill instead of returning an array.
    public static func chunks(from url: URL, recordedAt: Date) throws -> [AudioChunk] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw ImportError.unreadable(url) }
        converter.downmix = true

        var assembler = ChunkAssembler(sampleRate: sampleRate, source: .imported)
        var chunks: [AudioChunk] = []
        var emitted = 0
        var readError: Error?
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 16_384)
            else { throw ImportError.unreadable(url) }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { frames, inputStatus in
                guard file.framePosition < file.length,
                      let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames)
                else { inputStatus.pointee = .endOfStream; return nil }
                do { try file.read(into: input, frameCount: frames) } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if let readError { throw readError }
            if status == .error { throw error ?? ImportError.unreadable(url) }
            let count = Int(output.frameLength)
            if count > 0 {
                let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: count))
                chunks += assembler.append(samples, at: recordedAt.addingTimeInterval(Double(emitted) / sampleRate))
                emitted += count
            }
            if status == .endOfStream { break }
        }
        if let last = assembler.flush() { chunks.append(last) }
        return chunks
    }
}
