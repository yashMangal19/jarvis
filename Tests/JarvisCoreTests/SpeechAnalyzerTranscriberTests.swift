#if canImport(Speech)
import Foundation
import Testing
import JarvisCore
import AVFoundation
import Speech

@Suite struct SpeechAnalyzerTranscriberTests {
    private static let en = Locale(identifier: "en-IN")
    private static let hi = Locale(identifier: "hi-IN")

    @Test func notUsableWhenAnyPreferredLocaleIsUnsupported() async throws {
        guard #available(macOS 26, *) else { return }
        let usable = await SpeechAnalyzerTranscriber.isUsable(forPreferred: [Self.en, Self.hi]) { [Self.en] }
        #expect(usable == false)
    }

    @Test func usableWhenEveryPreferredLocaleIsSupported() async throws {
        guard #available(macOS 26, *) else { return }
        // A region-less preference ("hi") is met by any region of that language.
        let usable = await SpeechAnalyzerTranscriber.isUsable(forPreferred: [Self.en, Locale(identifier: "hi")]) {
            [Locale(identifier: "en-US"), Self.en, Self.hi]
        }
        #expect(usable)
    }

    @Test func notUsableWhenOnlyAnotherRegionIsSupported() async throws {
        guard #available(macOS 26, *) else { return }
        let usable = await SpeechAnalyzerTranscriber.isUsable(forPreferred: [Self.en]) { [Locale(identifier: "en-US")] }
        #expect(usable == false)
    }

    private static let sample = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".agentic/jarvis-ambient-memory/evidence/airpods3.wav")

    /// Smoke: real on-device transcription; skipped unless macOS 26+ with the English asset installed.
    private static func canSmoke() async -> Bool {
        guard FileManager.default.fileExists(atPath: sample.path) else { return false }
        if #available(macOS 26, *) {
            return await SpeechTranscriber.installedLocales.contains { $0.language.languageCode == "en" }
        }
        return false
    }

    @Test(.enabled("macOS 26+, English SpeechTranscriber asset installed, sample present") { await canSmoke() })
    func transcribesEnglishSample() async throws {
        guard #available(macOS 26, *) else { return }
        let file = try AVAudioFile(forReading: Self.sample)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let chunk = AudioChunk(samples: samples, sampleRate: file.processingFormat.sampleRate, start: Date(), source: .mic)

        let text = try await SpeechAnalyzerTranscriber(locale: Locale(identifier: "en-US")).transcribe(chunk)
        #expect(text.split(separator: " ").count >= 5)
    }
}
#endif
