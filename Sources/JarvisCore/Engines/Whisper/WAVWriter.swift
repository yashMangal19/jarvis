import AVFAudio
import Foundation

/// Encodes an `AudioChunk` as the WAV whisper.cpp reads: 16 kHz, mono, 16-bit PCM, 44-byte header.
public enum WAVWriter {
    static let sampleRate = 16_000.0

    public static func write(_ chunk: AudioChunk, to url: URL) throws {
        try data(for: chunk).write(to: url)
    }

    /// The WAV bytes, in memory only.
    static func data(for chunk: AudioChunk) throws -> Data {
        let samples = try resampled(chunk)
        var data = Data(capacity: 44 + samples.count * 2)
        let dataBytes = UInt32(samples.count * 2)

        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1))                     // PCM
        append(UInt16(1))                     // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)        // byte rate
        append(UInt16(2))                     // block align
        append(UInt16(16))                    // bits per sample
        data.append(contentsOf: Array("data".utf8)); append(dataBytes)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }

    /// The chunk's samples at 16 kHz; converted with AVAudioConverter when the rate differs.
    private static func resampled(_ chunk: AudioChunk) throws -> [Float] {
        if chunk.sampleRate == sampleRate || chunk.samples.isEmpty { return chunk.samples }
        guard let inFormat = AVAudioFormat(standardFormatWithSampleRate: chunk.sampleRate, channels: 1),
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(chunk.samples.count))
        else { throw WhisperError.audioConversion }
        input.frameLength = input.frameCapacity
        chunk.samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }

        let capacity = AVAudioFrameCount(Double(chunk.samples.count) * sampleRate / chunk.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)
        else { throw WhisperError.audioConversion }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .endOfStream; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { throw WhisperError.audioConversion }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
